#include "cmux_example/frontend.hpp"

#include <algorithm>
#include <set>
#include <string_view>
#include <thread>
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
    for (std::uint32_t index = 0; index < height; ++index) {
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
    std::set<std::uint32_t> seen;
    for (const auto& row : incoming) {
        if (row.row >= target.size()) {
            return cmux::make_error(
                cmux::ErrorCode::protocol,
                "a render delta row index is outside the current viewport");
        }
        if (!seen.insert(row.row).second) {
            return cmux::make_error(
                cmux::ErrorCode::protocol,
                "a render delta contains a duplicate row index");
        }
        target[row.row] = row;
    }
    return {};
}

[[nodiscard]] bool has_capability(
    const cmux::IdentifyResult& identify,
    std::string_view capability) {
    if (!identify.capabilities) {
        return false;
    }
    return std::ranges::find(*identify.capabilities, capability) !=
           identify.capabilities->end();
}

[[nodiscard]] const cmux::Tab* selected_tab(const cmux::Tree& tree) {
    const auto candidate_from_pane = [](const cmux::Pane& pane) -> const cmux::Tab* {
        const auto* live = std::get_if<cmux::LivePane>(&pane.value);
        if (!live || live->active_tab >= live->tabs.size()) {
            return nullptr;
        }
        const auto& tab = live->tabs[live->active_tab];
        return !tab.dead && tab.kind == cmux::TabKind::pty ? &tab : nullptr;
    };

    for (const auto& workspace : tree.workspaces) {
        if (!workspace.active) {
            continue;
        }
        for (const auto& screen : workspace.screens) {
            if (!screen.active) {
                continue;
            }
            for (const auto& pane : screen.panes) {
                const auto* live = std::get_if<cmux::LivePane>(&pane.value);
                if (live && live->id == screen.active_pane) {
                    if (const auto* tab = candidate_from_pane(pane)) {
                        return tab;
                    }
                }
            }
        }
    }

    for (const auto& workspace : tree.workspaces) {
        for (const auto& screen : workspace.screens) {
            for (const auto& pane : screen.panes) {
                const auto* live = std::get_if<cmux::LivePane>(&pane.value);
                if (!live) {
                    continue;
                }
                for (const auto& tab : live->tabs) {
                    if (!tab.dead && tab.kind == cmux::TabKind::pty) {
                        return &tab;
                    }
                }
            }
        }
    }
    return nullptr;
}

[[nodiscard]] bool tree_contains_surface(
    const cmux::Tree& tree,
    cmux::Id surface) {
    for (const auto& workspace : tree.workspaces) {
        for (const auto& screen : workspace.screens) {
            for (const auto& pane : screen.panes) {
                const auto* live = std::get_if<cmux::LivePane>(&pane.value);
                if (!live) {
                    continue;
                }
                for (const auto& tab : live->tabs) {
                    if (!tab.dead && tab.kind == cmux::TabKind::pty &&
                        tab.surface == surface) {
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

[[nodiscard]] bool client_is_attached(
    const cmux::ClientInfo& client,
    cmux::Id surface,
    std::uint16_t columns,
    std::uint16_t rows) {
    const bool attached =
        std::ranges::find(client.attached, surface) != client.attached.end();
    if (!attached) {
        return false;
    }
    return std::ranges::any_of(client.sizes, [&](const cmux::ClientSize& size) {
        return size.surface == surface && size.cols == columns && size.rows == rows;
    });
}

struct ConnectedAttempt {
    cmux::Client client;
    cmux::RenderStream stream;
    cmux::Id surface;
    std::uint64_t attachment_client;

    ConnectedAttempt(
        cmux::Client value_client,
        cmux::RenderStream value_stream,
        cmux::Id value_surface,
        std::uint64_t value_attachment_client)
        : client(std::move(value_client)),
          stream(std::move(value_stream)),
          surface(value_surface),
          attachment_client(value_attachment_client) {}

    ConnectedAttempt(ConnectedAttempt&&) noexcept = default;
    ConnectedAttempt& operator=(ConnectedAttempt&&) noexcept = default;
};

[[nodiscard]] cmux::Result<ConnectedAttempt> connect_attempt(
    const FrontendConfig& config) {
    auto connected = cmux::Client::connect(config.client_options);
    if (!connected) {
        return std::move(connected).error();
    }
    auto client = std::move(connected).value();

    auto identify = client.identify();
    if (!identify) {
        return std::move(identify).error();
    }
    if (identify.value().protocol < 10) {
        return cmux::make_error(
            cmux::ErrorCode::unsupported,
            "the terminal frontend requires cmux-tui protocol 10");
    }
    if (!has_capability(identify.value(), "attach-initial-size")) {
        return cmux::make_error(
            cmux::ErrorCode::unsupported,
            "the terminal frontend requires the attach-initial-size capability");
    }

    auto topology = client.list_workspaces();
    if (!topology) {
        return std::move(topology).error();
    }

    cmux::Id surface{};
    if (config.preferred_surface) {
        if (!tree_contains_surface(topology.value(), *config.preferred_surface)) {
            return cmux::make_error(
                cmux::ErrorCode::invalid_argument,
                "the requested surface is not a live PTY in list-workspaces");
        }
        surface = *config.preferred_surface;
    } else {
        const cmux::Tab* tab = selected_tab(topology.value());
        if (!tab) {
            return cmux::make_error(
                cmux::ErrorCode::invalid_argument,
                "list-workspaces contains no live PTY surface");
        }
        surface = tab->surface;
    }

    auto clients_before = client.list_clients();
    if (!clients_before) {
        return std::move(clients_before).error();
    }
    std::set<std::uint64_t> prior_client_ids;
    for (const auto& info : clients_before.value().value) {
        prior_client_ids.insert(info.client);
    }

    cmux::AttachSurfaceRequest attach_request;
    attach_request.surface = surface;
    attach_request.cols = cmux::Field<std::uint16_t>(config.columns);
    attach_request.rows = cmux::Field<std::uint16_t>(config.rows);
    auto attached = client.attach_render(attach_request);
    if (!attached) {
        return std::move(attached).error();
    }
    auto stream = std::move(attached).value();

    auto clients_after = client.list_clients();
    if (!clients_after) {
        return std::move(clients_after).error();
    }
    std::optional<std::uint64_t> attachment_client;
    for (const auto& info : clients_after.value().value) {
        if (!prior_client_ids.contains(info.client) &&
            client_is_attached(info, surface, config.columns, config.rows)) {
            if (attachment_client) {
                return cmux::make_error(
                    cmux::ErrorCode::protocol,
                    "multiple new clients match the render attachment");
            }
            attachment_client = info.client;
        }
    }
    if (!attachment_client) {
        return cmux::make_error(
            cmux::ErrorCode::protocol,
            "could not identify the SDK's render-stream connection in list-clients");
    }

    cmux::SetClientSizingRequest sizing;
    sizing.surface = surface;
    sizing.client = cmux::Field<std::uint64_t>(*attachment_client);
    sizing.enabled = true;
    sizing.exclusive = false;
    auto sized = client.set_client_sizing(sizing);
    if (!sized) {
        return std::move(sized).error();
    }

    return ConnectedAttempt(
        std::move(client), std::move(stream), surface, *attachment_client);
}

enum class OutcomeKind {
    stopped,
    detached,
    reconnect,
};

struct ConsumeOutcome {
    OutcomeKind kind;
    cmux::Error error;
};

[[nodiscard]] ConsumeOutcome consume_stream(
    ConnectedAttempt& attempt,
    ScreenBuffer& screen,
    FrontendStats& stats,
    const FrontendConfig& config,
    const TerminalFrontend::StopRequested& stop_requested,
    const TerminalFrontend::FrameCallback& on_frame) {
    while (!stop_requested()) {
        auto next = attempt.stream.next(config.stream_poll_timeout);
        if (!next) {
            if (next.error().code == cmux::ErrorCode::timeout) {
                continue;
            }
            ++stats.transport_failures;
            return {
                OutcomeKind::reconnect,
                std::move(next).error(),
            };
        }

        const cmux::Event& event = next.value();
        if (const auto* state = std::get_if<cmux::RenderStateEvent>(&event.value)) {
            if (state->surface != attempt.surface) {
                return {
                    OutcomeKind::reconnect,
                    cmux::make_error(
                        cmux::ErrorCode::protocol,
                        "render-state belongs to a different surface"),
                };
            }
            auto applied = screen.apply(*state);
            if (!applied) {
                return {OutcomeKind::reconnect, std::move(applied).error()};
            }
            ++stats.snapshots;
            if (on_frame) {
                on_frame(screen);
            }
            continue;
        }

        if (const auto* delta = std::get_if<cmux::RenderDeltaEvent>(&event.value)) {
            if (!screen.has_snapshot || delta->surface != attempt.surface) {
                return {
                    OutcomeKind::reconnect,
                    cmux::make_error(
                        cmux::ErrorCode::protocol,
                        "render-delta arrived before its matching render-state"),
                };
            }
            auto applied = screen.apply(*delta);
            if (!applied) {
                return {OutcomeKind::reconnect, std::move(applied).error()};
            }
            ++stats.deltas;
            if (on_frame) {
                on_frame(screen);
            }
            continue;
        }

        if (const auto* scroll = std::get_if<cmux::ScrollChangedEvent>(&event.value)) {
            if (!screen.has_snapshot || scroll->surface != attempt.surface) {
                return {
                    OutcomeKind::reconnect,
                    cmux::make_error(
                        cmux::ErrorCode::protocol,
                        "scroll-changed arrived before its matching render-state"),
                };
            }
            auto applied = screen.apply(*scroll);
            if (!applied) {
                return {OutcomeKind::reconnect, std::move(applied).error()};
            }
            ++stats.scroll_updates;
            if (on_frame) {
                on_frame(screen);
            }
            continue;
        }

        if (const auto* overflow = std::get_if<cmux::OverflowEvent>(&event.value)) {
            if (!overflow->surface || *overflow->surface == attempt.surface) {
                ++stats.overflows;
                return {
                    OutcomeKind::reconnect,
                    cmux::make_error(cmux::ErrorCode::protocol, overflow->error),
                };
            }
            continue;
        }

        if (const auto* detached = std::get_if<cmux::DetachedEvent>(&event.value)) {
            if (detached->surface == attempt.surface) {
                ++stats.detaches;
                return {OutcomeKind::detached, {}};
            }
            continue;
        }

        if (std::holds_alternative<cmux::UnknownEvent>(event.value)) {
            ++stats.unknown_events;
        }
    }
    return {OutcomeKind::stopped, {}};
}

[[nodiscard]] bool retryable(const cmux::Error& error) {
    return error.code != cmux::ErrorCode::invalid_argument &&
           error.code != cmux::ErrorCode::unsupported &&
           error.code != cmux::ErrorCode::command;
}

void wait_before_reconnect(
    std::chrono::milliseconds delay,
    const TerminalFrontend::StopRequested& stop_requested) {
    constexpr auto slice = std::chrono::milliseconds(10);
    while (delay > std::chrono::milliseconds::zero() && !stop_requested()) {
        const auto current = std::min(delay, slice);
        std::this_thread::sleep_for(current);
        delay -= current;
    }
}

}  // namespace

void ScreenBuffer::clear() noexcept {
    *this = ScreenBuffer{};
}

cmux::Result<void> ScreenBuffer::apply(const cmux::RenderStateEvent& event) {
    auto replaced = replace_rows(event.size.rows, event.rows);
    if (!replaced) {
        return std::move(replaced).error();
    }
    surface = event.surface;
    size = event.size;
    cursor = event.cursor;
    default_foreground = event.default_fg;
    default_background = event.default_bg;
    scrollback_rows = event.scrollback_rows;
    scroll_offset = 0;
    at_bottom = true;
    rows = std::move(replaced).value();
    has_snapshot = true;
    return {};
}

cmux::Result<void> ScreenBuffer::apply(const cmux::RenderDeltaEvent& event) {
    if (!has_snapshot || event.surface != surface) {
        return cmux::make_error(
            cmux::ErrorCode::protocol,
            "render delta does not match an initialized screen");
    }
    if (event.size && !event.full) {
        return cmux::make_error(
            cmux::ErrorCode::protocol,
            "a render delta with size must be a full replacement");
    }

    if (event.full) {
        const cmux::Size next_size = event.size.value_or(size);
        auto replaced = replace_rows(next_size.rows, event.rows);
        if (!replaced) {
            return std::move(replaced).error();
        }
        size = next_size;
        rows = std::move(replaced).value();
    } else {
        auto patched = patch_rows(rows, event.rows);
        if (!patched) {
            return std::move(patched).error();
        }
    }

    cursor = event.cursor;
    if (event.default_fg) {
        default_foreground = *event.default_fg;
    }
    if (event.default_bg) {
        default_background = *event.default_bg;
    }
    if (event.scrollback_rows) {
        scrollback_rows = *event.scrollback_rows;
    }
    return {};
}

cmux::Result<void> ScreenBuffer::apply(const cmux::ScrollChangedEvent& event) {
    if (!has_snapshot || event.surface != surface) {
        return cmux::make_error(
            cmux::ErrorCode::protocol,
            "scroll update does not match an initialized screen");
    }
    scroll_offset = event.offset;
    at_bottom = event.at_bottom;
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

    std::size_t reconnects_used = 0;
    while (!stop_requested()) {
        screen_.clear();
        selected_surface_.reset();
        auto attempt_result = connect_attempt(config_);
        if (!attempt_result) {
            cmux::Error error = std::move(attempt_result).error();
            if (!retryable(error) || reconnects_used >= config_.max_reconnects) {
                return error;
            }
            ++reconnects_used;
            ++stats_.reconnects;
            wait_before_reconnect(config_.reconnect_delay, stop_requested);
            continue;
        }

        ++stats_.connections;
        auto attempt = std::move(attempt_result).value();
        selected_surface_ = attempt.surface;
        ConsumeOutcome outcome = consume_stream(
            attempt, screen_, stats_, config_, stop_requested, on_frame);

        attempt.stream.close();
        attempt.client.close();

        if (outcome.kind == OutcomeKind::stopped ||
            outcome.kind == OutcomeKind::detached) {
            return {};
        }
        if (!retryable(outcome.error) ||
            reconnects_used >= config_.max_reconnects) {
            return std::move(outcome.error);
        }

        ++reconnects_used;
        ++stats_.reconnects;
        wait_before_reconnect(config_.reconnect_delay, stop_requested);
    }
    return {};
}

}  // namespace cmux_example
