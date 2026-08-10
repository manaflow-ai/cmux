#include "cmux_example/frontend.hpp"

#include <algorithm>
#include <set>
#include <string_view>
#include <utility>
#include <variant>

namespace cmux_example {
namespace {

[[nodiscard]] cmux::Result<std::vector<cmux::RenderRow>> replace_rows(
    std::uint16_t height,
    const std::vector<cmux::RenderRow>& incoming) {
    if (incoming.size() != static_cast<std::size_t>(height)) {
        return cmux::make_error(
            cmux::ErrorCode::protocol,
            "a complete render frame must contain exactly size.rows rows");
    }

    std::vector<cmux::RenderRow> result(height);
    std::vector<bool> seen(height, false);
    for (std::uint16_t index = 0; index < height; ++index) {
        result[index].row = index;
    }
    for (const auto& row : incoming) {
        if (row.row >= height) {
            return cmux::make_error(
                cmux::ErrorCode::protocol,
                "a render row index is outside the current viewport");
        }
        if (seen[row.row]) {
            return cmux::make_error(
                cmux::ErrorCode::protocol,
                "a complete render frame contains a duplicate row index");
        }
        seen[row.row] = true;
        result[row.row] = row;
    }
    return result;
}

[[nodiscard]] cmux::Result<void> patch_rows(
    std::vector<cmux::RenderRow>& target,
    const std::vector<cmux::RenderRow>& incoming) {
    std::set<std::uint16_t> seen;
    for (const auto& row : incoming) {
        if (row.row >= target.size()) {
            return cmux::make_error(
                cmux::ErrorCode::protocol,
                "a render patch row index is outside the current viewport");
        }
        if (!seen.insert(row.row).second) {
            return cmux::make_error(
                cmux::ErrorCode::protocol,
                "a render patch contains a duplicate row index");
        }
        target[row.row] = row;
    }
    return {};
}

[[nodiscard]] bool snapshot_contains(
    const cmux::ResourceSnapshot& snapshot,
    const cmux::TerminalId& id) {
    return std::ranges::any_of(
        snapshot.terminals,
        [&](const cmux::TerminalSnapshot& terminal) {
            return terminal.id == id;
        });
}

struct LaunchOutcome {
    cmux::TerminalId terminal_id;
    bool recovered = false;
};

[[nodiscard]] cmux::Result<LaunchOutcome> launch_terminal(
    const cmux::Session& session,
    const LaunchRequest& request) {
    auto mutation = cmux::MutationOptions::with_key(request.idempotency_key);
    if (!mutation) {
        return std::move(mutation).error();
    }

    cmux::RunOptions run(request.command);
    run.cwd = request.cwd;
    run.name = request.name;
    run.correlation_key = request.correlation_key;
    auto workspace = request.workspace
        ? session.workspace(*request.workspace)
        : session.workspace(
              cmux::Selector<cmux::WorkspaceId>::current());
    auto launched = workspace.run(
        std::move(run),
        std::move(mutation).value());
    if (launched) {
        return LaunchOutcome{
            std::move(launched).value().value.terminal_id,
            false,
        };
    }

    cmux::Error error = std::move(launched).error();
    if (error.code != cmux::ErrorCode::outcome_uncertain ||
        !error.uncertain_mutation) {
        return error;
    }
    const auto& uncertain = *error.uncertain_mutation;
    if (uncertain.operation != cmux::Operation::workspace_run ||
        uncertain.idempotency_key != request.idempotency_key) {
        return cmux::make_error(
            cmux::ErrorCode::protocol,
            "workspace.run returned mismatched uncertain mutation details");
    }

    auto resolved = session.resolve_creation(request.correlation_key);
    if (!resolved) {
        return std::move(resolved).error();
    }
    const auto& resolution = resolved.value();
    if (resolution.correlation_key != request.correlation_key ||
        resolution.state != cmux::CreationState::created) {
        return cmux::make_error(
            cmux::ErrorCode::protocol,
            "creation correlation did not resolve to a created path");
    }
    if (resolution.operation &&
        *resolution.operation !=
            cmux::operation_name(cmux::Operation::workspace_run)) {
        return cmux::make_error(
            cmux::ErrorCode::protocol,
            "creation correlation resolved to a different operation");
    }
    if (resolution.idempotency_key &&
        *resolution.idempotency_key != request.idempotency_key) {
        return cmux::make_error(
            cmux::ErrorCode::protocol,
            "creation correlation resolved to a different idempotency key");
    }
    if (!resolution.created_path) {
        return cmux::make_error(
            cmux::ErrorCode::protocol,
            "created resolution omitted its path");
    }
    const auto* path = std::get_if<cmux::CreatedTerminalPath>(
        &*resolution.created_path);
    if (!path) {
        return cmux::make_error(
            cmux::ErrorCode::protocol,
            "workspace.run resolution was not a terminal path");
    }
    return LaunchOutcome{path->terminal_id, true};
}

[[nodiscard]] bool exit_outcomes_equal(
    const cmux::TerminalExitOutcome& left,
    const cmux::TerminalExitOutcome& right) {
    if (left.index() != right.index()) {
        return false;
    }
    if (const auto* code = std::get_if<cmux::TerminalExitCode>(&left)) {
        return code->code ==
               std::get<cmux::TerminalExitCode>(right).code;
    }
    if (const auto* signal = std::get_if<cmux::TerminalExitSignal>(&left)) {
        const auto& other = std::get<cmux::TerminalExitSignal>(right);
        return signal->signal == other.signal &&
               signal->core_dumped == other.core_dumped;
    }
    return std::get<cmux::TerminalExitUnknown>(left).reason ==
           std::get<cmux::TerminalExitUnknown>(right).reason;
}

[[nodiscard]] cmux::Result<void> validate_wait_snapshot(
    const cmux::TerminalId& terminal_id,
    const cmux::TerminalWaitExitResult& waited,
    const cmux::TerminalSnapshot& snapshot) {
    if (snapshot.id != terminal_id) {
        return cmux::make_error(
            cmux::ErrorCode::protocol,
            "terminal.get returned a different opaque terminal ID");
    }
    if (const auto* exited =
            std::get_if<cmux::TerminalWaitExitExited>(&waited)) {
        if (exited->terminal_id != terminal_id ||
            snapshot.lifecycle != cmux::TerminalLifecycle::exited ||
            snapshot.running || !snapshot.exit) {
            return cmux::make_error(
                cmux::ErrorCode::protocol,
                "terminal.get did not retain the waited exit");
        }
        const auto& durable = *snapshot.exit;
        if (!exit_outcomes_equal(durable.outcome, exited->outcome) ||
            durable.exited_at != exited->exited_at ||
            durable.revision != exited->revision) {
            return cmux::make_error(
                cmux::ErrorCode::protocol,
                "terminal.get exit differs from terminal.wait_exit");
        }
        return {};
    }
    const auto& pending = std::get<cmux::TerminalWaitExitPending>(waited);
    if (pending.terminal_id != terminal_id) {
        return cmux::make_error(
            cmux::ErrorCode::protocol,
            "terminal.wait_exit returned a different terminal ID");
    }
    return {};
}

[[nodiscard]] cmux::Result<void> apply_item(
    ScreenBuffer& screen,
    FrontendStats& stats,
    const cmux::TerminalAttachmentItem& item,
    const TerminalFrontend::FrameCallback& on_frame) {
    cmux::Result<void> applied;
    bool changed = false;
    if (const auto* snapshot =
            std::get_if<cmux::TerminalAttachSnapshot>(&item)) {
        applied = screen.apply(*snapshot);
        ++stats.snapshots;
        changed = true;
    } else if (const auto* patch =
                   std::get_if<cmux::TerminalAttachPatch>(&item)) {
        applied = screen.apply(*patch);
        ++stats.patches;
        changed = true;
    } else if (const auto* scroll =
                   std::get_if<cmux::TerminalAttachScroll>(&item)) {
        applied = screen.apply(*scroll);
        ++stats.scroll_updates;
        changed = true;
    } else {
        ++stats.unknown_items;
        return {};
    }
    if (!applied) {
        return std::move(applied).error();
    }
    if (changed && on_frame) {
        on_frame(screen);
    }
    return {};
}

[[nodiscard]] cmux::Result<void> end_error(
    const std::optional<cmux::StreamEnd>& end) {
    if (!end ||
        (end->reason != cmux::StreamEndReason::gap &&
         end->reason != cmux::StreamEndReason::error)) {
        return {};
    }
    if (end->error) {
        return *end->error;
    }
    return cmux::make_error(
        cmux::ErrorCode::protocol,
        "terminal attachment ended without a recoverable snapshot boundary");
}

}  // namespace

void ScreenBuffer::clear() noexcept {
    *this = ScreenBuffer{};
}

cmux::Result<void> ScreenBuffer::apply(
    const cmux::TerminalAttachSnapshot& item) {
    auto replaced = replace_rows(item.render.size.rows, item.render.rows);
    if (!replaced) {
        return std::move(replaced).error();
    }
    terminal = item.terminal_id;
    size = item.render.size;
    cursor = item.render.cursor;
    default_foreground = item.render.default_fg;
    default_background = item.render.default_bg;
    scrollback_rows = item.render.scrollback_rows;
    scroll_offset = 0;
    at_bottom = true;
    rows = std::move(replaced).value();
    has_snapshot = true;
    return {};
}

cmux::Result<void> ScreenBuffer::apply(
    const cmux::TerminalAttachPatch& item) {
    if (!has_snapshot || !terminal || *terminal != item.terminal_id) {
        return cmux::make_error(
            cmux::ErrorCode::protocol,
            "render patch does not match an initialized terminal");
    }
    if (item.render.size && !item.render.full_reset) {
        return cmux::make_error(
            cmux::ErrorCode::protocol,
            "a render patch with size must be a full reset");
    }

    if (item.render.full_reset) {
        const cmux::Size next_size = item.render.size.value_or(size);
        auto replaced = replace_rows(next_size.rows, item.render.rows);
        if (!replaced) {
            return std::move(replaced).error();
        }
        size = next_size;
        rows = std::move(replaced).value();
    } else {
        auto patched = patch_rows(rows, item.render.rows);
        if (!patched) {
            return std::move(patched).error();
        }
    }

    cursor = item.render.cursor;
    if (item.render.default_fg) {
        default_foreground = *item.render.default_fg;
    }
    if (item.render.default_bg) {
        default_background = *item.render.default_bg;
    }
    if (item.render.scrollback_rows) {
        scrollback_rows = *item.render.scrollback_rows;
    }
    return {};
}

cmux::Result<void> ScreenBuffer::apply(
    const cmux::TerminalAttachScroll& item) {
    if (!has_snapshot || !terminal || *terminal != item.terminal_id) {
        return cmux::make_error(
            cmux::ErrorCode::protocol,
            "scroll update does not match an initialized terminal");
    }
    scroll_offset = item.scroll.offset;
    at_bottom = item.scroll.at_bottom;
    return {};
}

std::string ScreenBuffer::plain_text() const {
    std::string result;
    for (std::size_t index = 0; index < rows.size(); ++index) {
        for (const auto& run : rows[index].runs) {
            result += run.text;
        }
        if (index + 1 < rows.size()) {
            result.push_back('\n');
        }
    }
    return result;
}

cmux::Result<cmux::TerminalId> select_terminal(
    const cmux::ResourceSnapshot& snapshot) {
    for (const auto& tab : snapshot.tabs) {
        if (!tab.focused) {
            continue;
        }
        if (const auto* id = std::get_if<cmux::TerminalId>(
                &tab.content_id);
            id && snapshot_contains(snapshot, *id)) {
            return *id;
        }
    }
    const auto running = std::ranges::find_if(
        snapshot.terminals,
        [](const cmux::TerminalSnapshot& terminal) {
            return terminal.lifecycle == cmux::TerminalLifecycle::running;
        });
    if (running != snapshot.terminals.end()) {
        return running->id;
    }
    if (!snapshot.terminals.empty()) {
        return snapshot.terminals.front().id;
    }
    return cmux::make_error(
        cmux::ErrorCode::invalid_argument,
        "the session contains no terminal");
}

std::string plain_text(const cmux::TerminalHistoryResult& history) {
    std::string result;
    for (std::size_t index = 0; index < history.rows.size(); ++index) {
        for (const auto& run : history.rows[index].runs) {
            result += run.text;
        }
        if (index + 1 < history.rows.size()) {
            result.push_back('\n');
        }
    }
    return result;
}

TerminalFrontend::TerminalFrontend(FrontendConfig config)
    : config_(std::move(config)) {}

cmux::Result<void> TerminalFrontend::run(
    StopRequested stop_requested,
    FrameCallback on_frame) {
    if (!stop_requested) {
        return cmux::make_error(
            cmux::ErrorCode::invalid_argument,
            "a stop predicate is required");
    }
    if (config_.columns == 0 || config_.rows == 0) {
        return cmux::make_error(
            cmux::ErrorCode::invalid_argument,
            "the frontend grid must be non-zero");
    }
    if (config_.stream_poll_timeout <= std::chrono::milliseconds::zero()) {
        return cmux::make_error(
            cmux::ErrorCode::invalid_argument,
            "the stream poll timeout must be positive");
    }
    if (config_.preferred_terminal && config_.launch) {
        return cmux::make_error(
            cmux::ErrorCode::invalid_argument,
            "preferred_terminal and launch are mutually exclusive");
    }

    screen_.clear();
    stats_ = {};
    selected_terminal_.reset();
    recovered_launch_ = false;
    initial_screen_.reset();
    initial_history_.reset();
    initial_terminal_.reset();
    exit_wait_.reset();
    final_terminal_.reset();
    stream_end_.reset();

    auto connected = cmux::Client::connect(config_.client_options);
    if (!connected) {
        return std::move(connected).error();
    }
    auto client = std::move(connected).value();
    auto session =
        client.session(cmux::Selector<cmux::SessionId>::current());

    if (config_.launch) {
        auto launched = launch_terminal(session, *config_.launch);
        if (!launched) {
            return std::move(launched).error();
        }
        selected_terminal_ = launched.value().terminal_id;
        recovered_launch_ = launched.value().recovered;
    } else if (config_.preferred_terminal) {
        selected_terminal_ = config_.preferred_terminal;
    } else {
        auto snapshot = session.snapshot();
        if (!snapshot) {
            return std::move(snapshot).error();
        }
        auto selected = select_terminal(snapshot.value());
        if (!selected) {
            return std::move(selected).error();
        }
        selected_terminal_ = std::move(selected).value();
    }

    auto terminal = client.terminal(*selected_terminal_);
    auto before = terminal.refresh();
    if (!before) {
        return std::move(before).error();
    }
    initial_terminal_ = std::move(before).value();
    auto screen = terminal.read_screen();
    if (!screen) {
        return std::move(screen).error();
    }
    initial_screen_ = std::move(screen).value();
    cmux::TerminalHistoryOptions history_options;
    history_options.limit = 10'000;
    history_options.styled = true;
    auto history = terminal.read_history(history_options);
    if (!history) {
        return std::move(history).error();
    }
    initial_history_ = std::move(history).value();

    cmux::TerminalAttachOptions attach_options;
    attach_options.read_only = true;
    auto attached = terminal.attach(attach_options);
    if (!attached) {
        return std::move(attached).error();
    }
    auto stream = std::move(attached).value();
    auto resized = stream.resize_viewer(config_.columns, config_.rows);
    if (!resized) {
        auto ignored = stream.cancel();
        static_cast<void>(ignored);
        return std::move(resized).error();
    }
    if (!resized.value().accepted) {
        auto ignored = stream.cancel();
        static_cast<void>(ignored);
        return cmux::make_error(
            cmux::ErrorCode::command,
            "terminal viewer rejected the requested grid");
    }

    while (!stop_requested()) {
        auto next = stream.poll(config_.stream_poll_timeout);
        if (!next) {
            if (next.error().code == cmux::ErrorCode::timeout) {
                ++stats_.poll_timeouts;
                continue;
            }
            cmux::Error failure = std::move(next).error();
            if (!stream.closed()) {
                auto ignored = stream.cancel();
                static_cast<void>(ignored);
            }
            return failure;
        }
        if (!next.value()) {
            stream_end_ = stream.end();
            break;
        }
        auto applied = apply_item(
            screen_,
            stats_,
            next.value()->value,
            on_frame);
        if (!applied) {
            auto ignored = stream.cancel();
            static_cast<void>(ignored);
            return std::move(applied).error();
        }
    }

    if (!stream.closed()) {
        auto released = stream.release_viewer();
        if (!released) {
            auto ignored = stream.cancel();
            static_cast<void>(ignored);
            return std::move(released).error();
        }
        auto canceled = stream.cancel();
        if (!canceled) {
            return std::move(canceled).error();
        }
        ++stats_.cancellations;
        stream_end_ = std::move(canceled).value();
    }
    auto ended = end_error(stream_end_);
    if (!ended) {
        return std::move(ended).error();
    }

    auto waited = terminal.wait_exit(0);
    if (!waited) {
        return std::move(waited).error();
    }
    exit_wait_ = std::move(waited).value();
    auto after = terminal.refresh();
    if (!after) {
        return std::move(after).error();
    }
    final_terminal_ = std::move(after).value();
    return validate_wait_snapshot(
        *selected_terminal_,
        *exit_wait_,
        *final_terminal_);
}

}  // namespace cmux_example
