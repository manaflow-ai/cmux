#include "test.hpp"

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <stop_token>
#include <string>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>

#include "cmux/client.hpp"
#include "cmux/raw/client.hpp"
#include "resource_test_hooks.hpp"

namespace {

struct FakeState {
    std::mutex mutex;
    std::condition_variable changed;
    std::deque<std::string> incoming;
    std::vector<std::string> outgoing;
    std::size_t receive_timeouts = 0;
    std::optional<cmux::Timeout> receive_delay;
    std::size_t send_calls = 0;
    std::optional<std::size_t> fail_send_call;
    bool record_failed_send = false;
    std::size_t close_calls = 0;
    bool closed = false;
};

class FakeTransport final : public cmux::Transport {
public:
    explicit FakeTransport(std::shared_ptr<FakeState> state)
        : state_(std::move(state)) {}

    cmux::Result<void> send(
        std::string_view message,
        cmux::Timeout) override {
        std::lock_guard lock(state_->mutex);
        if (state_->closed) {
            return cmux::make_error(cmux::ErrorCode::closed, "fake closed");
        }
        ++state_->send_calls;
        if (state_->fail_send_call == state_->send_calls) {
            if (state_->record_failed_send) {
                state_->outgoing.emplace_back(message);
            }
            state_->changed.notify_all();
            return cmux::make_error(
                cmux::ErrorCode::connection,
                "synthetic framing-uncertain send failure");
        }
        state_->outgoing.emplace_back(message);
        state_->changed.notify_all();
        return {};
    }

    cmux::Result<std::string> receive(cmux::Timeout timeout) override {
        std::unique_lock lock(state_->mutex);
        if (state_->receive_delay) {
            const auto delay = std::min(timeout, *state_->receive_delay);
            lock.unlock();
            std::this_thread::sleep_for(delay);
            lock.lock();
            if (timeout <= *state_->receive_delay) {
                ++state_->receive_timeouts;
                state_->changed.notify_all();
                return cmux::make_error(
                    cmux::ErrorCode::timeout,
                    "fake timeout");
            }
        }
        if (!state_->changed.wait_for(lock, timeout, [this] {
                return state_->closed || !state_->incoming.empty();
            })) {
            ++state_->receive_timeouts;
            state_->changed.notify_all();
            return cmux::make_error(cmux::ErrorCode::timeout, "fake timeout");
        }
        if (!state_->incoming.empty()) {
            std::string result = std::move(state_->incoming.front());
            state_->incoming.pop_front();
            return result;
        }
        return cmux::make_error(cmux::ErrorCode::closed, "fake closed");
    }

    void close() noexcept override {
        std::lock_guard lock(state_->mutex);
        ++state_->close_calls;
        state_->closed = true;
        state_->changed.notify_all();
    }

private:
    std::shared_ptr<FakeState> state_;
};

cmux::TransportFactory fake_factory(
    const std::shared_ptr<FakeState>& state) {
    return [state]() -> cmux::Result<std::unique_ptr<cmux::Transport>> {
        return std::unique_ptr<cmux::Transport>(new FakeTransport(state));
    };
}

void enqueue(
    const std::shared_ptr<FakeState>& state,
    std::string message) {
    std::lock_guard lock(state->mutex);
    state->incoming.push_back(std::move(message));
    state->changed.notify_all();
}

void wait_for_writes(
    const std::shared_ptr<FakeState>& state,
    std::size_t count) {
    std::unique_lock lock(state->mutex);
    state->changed.wait(lock, [&] { return state->outgoing.size() >= count; });
}

void wait_for_receive_timeouts(
    const std::shared_ptr<FakeState>& state,
    std::size_t count) {
    std::unique_lock lock(state->mutex);
    (void)state->changed.wait_for(
        lock,
        std::chrono::seconds(1),
        [&] { return state->receive_timeouts >= count; });
}

cmux::Client client_for(
    const std::shared_ptr<FakeState>& control,
    const std::shared_ptr<FakeState>& stream = {},
    cmux::Timeout timeout = std::chrono::seconds(2)) {
    cmux::ClientOptions options;
    options.timeout = timeout;
    options.transport_factory = fake_factory(control);
    options.stream_transport_factory =
        fake_factory(stream ? stream : control);
    auto connected = cmux::Client::connect(std::move(options));
    if (!connected) {
        throw std::runtime_error(connected.error().message);
    }
    return std::move(connected).value();
}

std::string response(
    std::string id,
    std::string result = "{}") {
    return "{\"protocol\":\"cmux.protocol/2\",\"type\":\"response\",\"id\":\"" +
           id + "\",\"ok\":true,\"result\":" + result + "}";
}

std::string stream_open_response(
    const std::string& request_id,
    const std::string& stream_id) {
    return response(
        request_id,
        "{\"stream_id\":\"" + stream_id + "\"}");
}

std::string attachment_open_response(
    const std::string& request_id,
    const std::string& stream_id,
    const std::string& attachment_lease) {
    return response(
        request_id,
        "{\"stream_id\":\"" + stream_id +
            "\",\"attachment_lease\":\"" + attachment_lease + "\"}");
}

std::string resource_snapshot(std::uint64_t revision) {
    const auto decimal = std::to_string(revision);
    return
        "{\"machine\":{\"id\":\"machine_00000000000000000000000000000000\","
        "\"name\":\"local\",\"origin\":\"local\",\"status\":\"running\","
        "\"connectable\":true,\"deleted\":false,\"recoverable\":false},"
        "\"session\":{\"id\":\"session_00000000000000000000000000000000\","
        "\"machine_id\":\"machine_00000000000000000000000000000000\","
        "\"generation\":\"g\",\"revision\":\"" + decimal +
        "\",\"connected\":true},\"workspaces\":[],\"screens\":[],"
        "\"panes\":[],\"tabs\":[],\"terminals\":[],\"browsers\":[],"
        "\"clients\":[],\"notifications\":[],\"agents\":[],"
        "\"frontend_projections\":[],\"sidebar_views\":[],"
        "\"cursor\":{\"generation\":\"g\",\"revision\":\"" + decimal + "\"}}";
}

std::string error_response(
    std::string id,
    std::string code,
    std::string details = "{}") {
    return "{\"protocol\":\"cmux.protocol/2\",\"type\":\"response\",\"id\":\"" +
           id + "\",\"ok\":false,\"error\":{\"code\":\"" + code +
           "\",\"message\":\"test error\",\"details\":" + details +
           ",\"retryable\":false}}";
}

}  // namespace

static_assert(!std::is_copy_constructible_v<cmux::ResourceStream>);
static_assert(std::is_nothrow_move_constructible_v<cmux::ResourceStream>);
static_assert(!std::is_copy_constructible_v<cmux::TerminalAttachmentStream>);
static_assert(std::variant_size_v<cmux::SessionEvent> == 3);
static_assert(std::is_same_v<
              std::variant_alternative_t<0, cmux::SessionEvent>,
              cmux::SessionSnapshotEvent>);
static_assert(std::is_same_v<
              std::variant_alternative_t<1, cmux::SessionEvent>,
              cmux::SessionDeltaEvent>);
static_assert(std::is_same_v<
              std::variant_alternative_t<2, cmux::SessionEvent>,
              cmux::Unknown>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::raw::Client&>().identify()),
              cmux::Result<cmux::raw::IdentifyResult>>);
template <typename T>
concept HasMutationReceipt = requires(T value) {
    value.receipt;
};
static_assert(!HasMutationReceipt<cmux::RawMutationResult>);

TEST("resource IDs and selectors never expose mux numbers") {
    auto id = cmux::WorkspaceId::parse(
        "ws_0123456789abcdef0123456789abcdef");
    CHECK(id);
    CHECK_EQ(
        cmux::Selector<cmux::WorkspaceId>::by_id(id.value()).wire(),
        id.value().value());
    CHECK_EQ(
        cmux::Selector<cmux::WorkspaceId>::current().wire(),
        std::string("current"));
    CHECK_EQ(
        cmux::Selector<cmux::WorkspaceId>::exact_name("current").wire(),
        std::string("name:current"));
    CHECK_EQ(
        cmux::Selector<cmux::WorkspaceId>::exact_name("").wire(),
        std::string("name:"));
    CHECK(!cmux::WorkspaceId::parse("42"));
    CHECK(!cmux::WorkspaceId::parse(
        "ws_0123456789ABCDEF0123456789ABCDEF"));
}

TEST("run commands preserve exact argv and keep shell evaluation remote") {
    auto exact = cmux::RunCommand::exact(
        {"printf", "%s", "hello world", "$HOME"});
    CHECK(exact);
    cmux::RunOptions exact_options(std::move(exact).value());
    auto exact_params = exact_options.to_params();
    CHECK(exact_params);
    CHECK(exact_params.value().contains("argv"));
    CHECK(!exact_params.value().contains("shell"));
    const auto* argv =
        exact_params.value().at("argv").as_array().value();
    CHECK_EQ(argv->size(), 4U);
    CHECK_EQ(argv->at(3).as_string().value(), std::string_view("$HOME"));

    auto shell = cmux::RunCommand::shell("echo $REMOTE_HOME");
    CHECK(shell);
    cmux::RunOptions shell_options(std::move(shell).value());
    auto shell_params = shell_options.to_params();
    CHECK(shell_params);
    CHECK(shell_params.value().contains("shell"));
    CHECK(!shell_params.value().contains("argv"));
    CHECK_EQ(
        shell_params.value().at("shell").as_string().value(),
        std::string_view("echo $REMOTE_HOME"));

    auto explicit_shell = cmux::RunCommand::shell_with_executable(
        "/bin/zsh", "echo ok");
    CHECK(explicit_shell);
    CHECK_EQ(explicit_shell.value().argv().at(0), std::string("/bin/zsh"));
    CHECK_EQ(explicit_shell.value().argv().at(1), std::string("-lc"));
}

TEST("terminal history and attach options validate and encode") {
    cmux::TerminalHistoryOptions history;
    history.before = std::numeric_limits<std::uint64_t>::max();
    history.limit = 10'000;
    history.styled = true;
    auto history_params = history.to_params();
    CHECK(history_params);
    CHECK_EQ(
        history_params.value().at("before").as_string().value(),
        std::string_view("18446744073709551615"));
    CHECK_EQ(
        history_params.value().at("limit").as_uint64().value(),
        10'000U);
    CHECK(history_params.value().at("styled").as_bool().value());

    cmux::TerminalHistoryOptions plain_history;
    plain_history.styled = false;
    auto plain_history_params = plain_history.to_params();
    CHECK(plain_history_params);
    CHECK(!plain_history_params.value().at("styled").as_bool().value());

    cmux::TerminalHistoryOptions default_history;
    auto default_history_params = default_history.to_params();
    CHECK(default_history_params);
    CHECK(!default_history_params.value().contains("styled"));

    cmux::TerminalHistoryOptions zero_limit;
    zero_limit.limit = 0;
    auto invalid_zero_limit = zero_limit.to_params();
    CHECK(!invalid_zero_limit);
    CHECK_EQ(
        invalid_zero_limit.error().code,
        cmux::ErrorCode::invalid_argument);

    cmux::TerminalHistoryOptions oversized_limit;
    oversized_limit.limit = 10'001;
    CHECK(!oversized_limit.to_params());

    cmux::TerminalAttachOptions attach;
    attach.cols = 120;
    attach.rows = 40;
    attach.read_only = true;
    auto attach_params = attach.to_params();
    CHECK(attach_params);
    CHECK_EQ(
        attach_params.value().at("cols").as_uint64().value(),
        120U);
    CHECK_EQ(
        attach_params.value().at("rows").as_uint64().value(),
        40U);
    CHECK(attach_params.value().at("read_only").as_bool().value());

    cmux::TerminalAttachOptions unpaired;
    unpaired.cols = 80;
    auto invalid_unpaired = unpaired.to_params();
    CHECK(!invalid_unpaired);
    CHECK_EQ(
        invalid_unpaired.error().code,
        cmux::ErrorCode::invalid_argument);

    cmux::TerminalAttachOptions zero_size;
    zero_size.cols = 0;
    zero_size.rows = 24;
    CHECK(!zero_size.to_params());

    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    auto terminal_id = cmux::TerminalId::parse(
        "term_0123456789abcdef0123456789abcdef");
    CHECK(terminal_id);
    auto terminal = client.terminal(std::move(terminal_id).value());
    auto rejected_history = terminal.read_history(zero_limit);
    CHECK(!rejected_history);
    auto rejected_attach = terminal.attach(unpaired);
    CHECK(!rejected_attach);
    std::lock_guard lock(state->mutex);
    CHECK(state->outgoing.empty());
}

TEST("terminal history handle sends only validated typed fields") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    enqueue(
        state,
        response(
            "cpp-request-1",
            R"({"start":"0","next":null,"rows":[]})"));
    auto id = cmux::TerminalId::parse(
        "term_0123456789abcdef0123456789abcdef");
    CHECK(id);
    cmux::TerminalHistoryOptions options;
    options.before = 42;
    options.limit = 250;
    options.styled = true;
    auto history = client.terminal(std::move(id).value())
                       .read_history(options);
    CHECK(history);

    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 1U);
    auto envelope = cmux::Json::parse(state->outgoing.front());
    CHECK(envelope);
    const auto* params =
        envelope.value().find("params")->as_object().value();
    CHECK_EQ(
        params->at("terminal").as_string().value(),
        std::string_view(
            "term_0123456789abcdef0123456789abcdef"));
    CHECK_EQ(
        params->at("before").as_string().value(),
        std::string_view("42"));
    CHECK_EQ(params->at("limit").as_uint64().value(), 250U);
    CHECK(params->at("styled").as_bool().value());
}

TEST("session auxiliary APIs emit typed notification and agent routes") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    enqueue(
        state,
        response(
            "cpp-request-1",
            R"([{"id":"notification_11111111111111111111111111111111","session_id":"session_22222222222222222222222222222222","title":"queued","body":"waiting","level":"info","created_at_ms":"19","unread":true}])"));
    enqueue(
        state,
        response(
            "cpp-request-2",
            R"({"value":{"id":"notification_33333333333333333333333333333333","session_id":"session_22222222222222222222222222222222","title":"build","body":"failed","level":"warning","terminal_id":"term_44444444444444444444444444444444","created_at_ms":"20","unread":true},"generation":"g","revision":"21","replayed":false})"));
    enqueue(
        state,
        response(
            "cpp-request-3",
            R"({"value":{"id":"agent_55555555555555555555555555555555","session_id":"session_22222222222222222222222222222222","terminal_id":"term_44444444444444444444444444444444","state":"working","source":"socket","updated_at_ms":"21","source_session":"codex-task-42"},"generation":"g","revision":"22","replayed":false})"));

    auto machine_id = cmux::MachineId::parse(
        "machine_11111111111111111111111111111111");
    auto session_id = cmux::SessionId::parse(
        "session_22222222222222222222222222222222");
    auto terminal_id = cmux::TerminalId::parse(
        "term_44444444444444444444444444444444");
    CHECK(machine_id);
    CHECK(session_id);
    CHECK(terminal_id);
    auto session =
        client.machine(std::move(machine_id).value())
            .session(std::move(session_id).value());

    auto notifications = session.notifications(25);
    CHECK(notifications);
    CHECK_EQ(notifications.value().size(), 1U);
    CHECK_EQ(
        notifications.value().front().level,
        cmux::NotificationLevel::info);

    cmux::NotificationCreateOptions notification("build", "failed");
    notification.level = cmux::NotificationLevel::warning;
    notification.terminal_id = terminal_id.value();
    auto notification_key =
        cmux::MutationOptions::with_key("notification-create-1");
    CHECK(notification_key);
    auto created = session.create_notification(
        std::move(notification),
        std::move(notification_key).value().expecting(20));
    CHECK(created);
    CHECK_EQ(created.value().revision, 21U);
    CHECK_EQ(
        created.value().value.level,
        cmux::NotificationLevel::warning);

    cmux::AgentReportOptions report(
        terminal_id.value(),
        cmux::AgentState::working,
        cmux::AgentReportSource::socket);
    report.source_session = "codex-task-42";
    auto agent_key = cmux::MutationOptions::with_key("agent-report-1");
    CHECK(agent_key);
    auto reported = session.report_agent(
        std::move(report),
        std::move(agent_key).value().expecting(21));
    CHECK(reported);
    CHECK_EQ(reported.value().revision, 22U);
    CHECK_EQ(reported.value().value.state, cmux::AgentState::working);
    CHECK_EQ(reported.value().value.source, cmux::AgentSource::socket);

    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 3U);
    const auto list_envelope = cmux::Json::parse(state->outgoing.at(0));
    const auto create_envelope = cmux::Json::parse(state->outgoing.at(1));
    const auto report_envelope = cmux::Json::parse(state->outgoing.at(2));
    CHECK(list_envelope);
    CHECK(create_envelope);
    CHECK(report_envelope);

    CHECK_EQ(
        list_envelope.value().find("operation")->as_string().value(),
        std::string_view("notification.list"));
    CHECK(list_envelope.value().find("idempotency_key") == nullptr);
    const auto* list_params =
        list_envelope.value().find("params")->as_object().value();
    CHECK_EQ(list_params->at("limit").as_uint64().value(), 25U);
    CHECK_EQ(
        list_params->at("machine").as_string().value(),
        std::string_view(
            "machine_11111111111111111111111111111111"));
    CHECK_EQ(
        list_params->at("session").as_string().value(),
        std::string_view(
            "session_22222222222222222222222222222222"));

    CHECK_EQ(
        create_envelope.value().find("operation")->as_string().value(),
        std::string_view("notification.create"));
    CHECK_EQ(
        create_envelope.value()
            .find("idempotency_key")
            ->as_string()
            .value(),
        std::string_view("notification-create-1"));
    const auto* create_params =
        create_envelope.value().find("params")->as_object().value();
    CHECK_EQ(
        create_params->at("title").as_string().value(),
        std::string_view("build"));
    CHECK_EQ(
        create_params->at("body").as_string().value(),
        std::string_view("failed"));
    CHECK_EQ(
        create_params->at("level").as_string().value(),
        std::string_view("warning"));
    CHECK_EQ(
        create_params->at("terminal_id").as_string().value(),
        std::string_view(
            "term_44444444444444444444444444444444"));
    CHECK_EQ(
        create_params->at("expected_revision").as_string().value(),
        std::string_view("20"));
    CHECK(!create_params->contains("notification"));

    CHECK_EQ(
        report_envelope.value().find("operation")->as_string().value(),
        std::string_view("agent.report"));
    CHECK_EQ(
        report_envelope.value()
            .find("idempotency_key")
            ->as_string()
            .value(),
        std::string_view("agent-report-1"));
    const auto* report_params =
        report_envelope.value().find("params")->as_object().value();
    CHECK_EQ(
        report_params->at("terminal_id").as_string().value(),
        std::string_view(
            "term_44444444444444444444444444444444"));
    CHECK_EQ(
        report_params->at("state").as_string().value(),
        std::string_view("working"));
    CHECK_EQ(
        report_params->at("source").as_string().value(),
        std::string_view("socket"));
    CHECK_EQ(
        report_params->at("source_session").as_string().value(),
        std::string_view("codex-task-42"));
    CHECK_EQ(
        report_params->at("expected_revision").as_string().value(),
        std::string_view("21"));
    CHECK(!report_params->contains("agent"));
}

TEST("session auxiliary options reject invalid values before I/O") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    auto session =
        client.session(cmux::Selector<cmux::SessionId>::current());

    CHECK(!session.notifications(0));
    CHECK(!session.notifications(1'001));
    CHECK(!session.create_notification(
        cmux::NotificationCreateOptions("", "body")));
    CHECK(!session.report_agent(cmux::AgentReportOptions(
        cmux::TerminalId{},
        cmux::AgentState::working,
        cmux::AgentReportSource::hook)));

    std::lock_guard lock(state->mutex);
    CHECK(state->outgoing.empty());
}

TEST("all creation options validate and encode correlation keys") {
    const auto check = [](cmux::Result<cmux::Json::Object> params) {
        CHECK(params);
        CHECK_EQ(
            params.value().at("correlation_key").as_string().value(),
            std::string_view("create-correlation"));
    };

    cmux::CreateWorkspaceOptions workspace;
    workspace.correlation_key = "create-correlation";
    check(workspace.to_params());

    auto exact = cmux::RunCommand::exact({"true"});
    CHECK(exact);
    cmux::RunOptions run(std::move(exact).value());
    run.correlation_key = "create-correlation";
    check(run.to_params());

    cmux::CreateScreenOptions screen;
    screen.correlation_key = "create-correlation";
    check(screen.to_params());

    cmux::CreatePaneOptions pane;
    pane.correlation_key = "create-correlation";
    check(pane.to_params());

    cmux::SplitPaneOptions split(cmux::PaneDirection::right);
    split.correlation_key = "create-correlation";
    split.viewport_width = 0.5;
    check(split.to_params());
    CHECK_EQ(
        split.to_params().value().at("viewport_width").as_double().value(),
        0.5);

    cmux::CreateTerminalTabOptions terminal;
    terminal.correlation_key = "create-correlation";
    check(terminal.to_params());

    cmux::CreateBrowserTabOptions browser("https://example.com");
    browser.correlation_key = "create-correlation";
    check(browser.to_params());

    cmux::CreateScreenOptions empty;
    empty.correlation_key = "";
    auto invalid_empty = empty.to_params();
    CHECK(!invalid_empty);
    CHECK_EQ(
        invalid_empty.error().code,
        cmux::ErrorCode::invalid_argument);

    cmux::CreatePaneOptions oversized;
    oversized.correlation_key = std::string(129, 'x');
    CHECK(!oversized.to_params());
}

TEST("operation classes contain capability corrections") {
    CHECK_EQ(
        cmux::operation_name(cmux::Operation::terminal_renderer_grant_create),
        std::string_view("terminal.renderer_grant.create"));
    CHECK_EQ(
        cmux::operation_class(cmux::Operation::client_detach),
        cmux::OperationClass::connection_control);
    CHECK_EQ(
        cmux::operation_class(cmux::Operation::client_cell_pixels_set),
        cmux::OperationClass::connection_control);
    CHECK_EQ(
        cmux::operation_class(cmux::Operation::client_metadata_update),
        cmux::OperationClass::connection_control);
    CHECK_EQ(
        cmux::operation_class(cmux::Operation::request_cancel),
        cmux::OperationClass::connection_control);
    CHECK_EQ(
        cmux::operation_name(cmux::Operation::tab_create_browser),
        std::string_view("tab.create_browser"));
}

TEST("idempotency keys match the durable identifier contract") {
    std::string exact_limit;
    for (std::size_t index = 0; index < 64U; ++index) {
        exact_limit += "\xC3\xA9";
    }
    auto over_limit = exact_limit + "\xC3\xA9";
    const std::vector<std::string> invalid{
        "",
        " \xC2\xA0\xE3\x80\x80",
        "key\ncontrol",
        "key\xC2\x85" "control",
        over_limit,
        std::string("key\xFF", 4),
    };
    for (const auto& value : invalid) {
        CHECK(!cmux::MutationOptions::with_key(value));
    }
    for (const auto& value : std::vector<std::string>{
             " key ",
             "\xEF\xBB\xBF",
             exact_limit,
         }) {
        auto key = cmux::MutationOptions::with_key(value);
        CHECK(key);
        CHECK_EQ(key.value().idempotency_key(), value);
    }
}

TEST("mutation sends one stable injected idempotency key without retry") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    enqueue(
        state,
        response(
            "cpp-request-1",
            R"({"value":{"name":""},"generation":"g","revision":"7","replayed":false})"));
    auto key = cmux::MutationOptions::with_key("test-stable-key");
    CHECK(key);
    auto result = client.mutate(
        cmux::Operation::workspace_rename,
        {
            {"workspace",
             cmux::Json("ws_0123456789abcdef0123456789abcdef")},
            {"name", cmux::Json("")},
        },
        std::move(key).value().expecting(42));
    CHECK(result);
    CHECK_EQ(result.value().generation, std::string("g"));
    CHECK_EQ(result.value().revision, 7U);
    CHECK(!result.value().replayed);
    CHECK(result.value().value.find("name") != nullptr);

    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 1U);
    auto envelope = cmux::Json::parse(state->outgoing.front());
    CHECK(envelope);
    CHECK_EQ(
        envelope.value().find("operation")->as_string().value(),
        std::string_view("workspace.rename"));
    CHECK_EQ(
        envelope.value().find("idempotency_key")->as_string().value(),
        std::string_view("test-stable-key"));
    const auto* params =
        envelope.value().find("params")->as_object().value();
    CHECK_EQ(
        params->at("name").as_string().value(),
        std::string_view(""));
    CHECK_EQ(
        params->at("machine").as_string().value(),
        std::string_view("current"));
    CHECK_EQ(
        params->at("session").as_string().value(),
        std::string_view("current"));
    CHECK_EQ(
        params->at("expected_revision").as_string().value(),
        std::string_view("42"));
}

TEST("workspace creation accepts an expected resource revision") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    enqueue(
        state,
        response(
            "cpp-request-1",
            R"({"value":{"kind":"workspace","workspace_id":"ws_0123456789abcdef0123456789abcdef"},"generation":"g","revision":"1","replayed":false})"));
    auto key = cmux::MutationOptions::with_key("workspace-create-key");
    CHECK(key);
    auto result = client.mutate(
        cmux::Operation::workspace_create,
        {{"initial_content", cmux::Json("empty")}},
        std::move(key).value().expecting(0));
    CHECK(result);

    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 1U);
    auto envelope = cmux::Json::parse(state->outgoing.front());
    CHECK(envelope);
    CHECK_EQ(
        envelope.value().find("operation")->as_string().value(),
        std::string_view("workspace.create"));
    const auto* params =
        envelope.value().find("params")->as_object().value();
    CHECK_EQ(
        params->at("expected_revision").as_string().value(),
        std::string_view("0"));
}

TEST("default idempotency keys contain independent random 128-bit values") {
    const auto first = cmux::MutationOptions::unique().idempotency_key();
    const auto second = cmux::MutationOptions::unique().idempotency_key();
    CHECK_EQ(first.size(), std::string("cpp_").size() + 32U);
    CHECK_EQ(second.size(), std::string("cpp_").size() + 32U);
    CHECK(first != second);
}

TEST("structured protocol errors retain code details and retryability") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    enqueue(
        state,
        R"({"protocol":"cmux.protocol/2","type":"response","id":"cpp-request-1","ok":false,"error":{"code":"selector.ambiguous","message":"two matches","details":{"token":"must-not-log","candidates":["ws_0123456789abcdef0123456789abcdef"]},"retryable":false}})");
    auto result = client.read(cmux::Operation::workspace_get);
    CHECK(!result);
    CHECK_EQ(
        result.error().protocol_code,
        std::string("selector.ambiguous"));
    CHECK_EQ(result.error().message, std::string("two matches"));
    CHECK(result.error().details != nullptr);
    auto details = result.error().details->encode();
    CHECK(details);
    CHECK(details.value().find("must-not-log") == std::string::npos);
    CHECK(details.value().find("[REDACTED]") != std::string::npos);
    CHECK(!result.error().retryable);
}

TEST("responses require exact v2 success and error variants") {
    const auto run = [](std::string fields) {
        auto state = std::make_shared<FakeState>();
        auto client = client_for(state);
        enqueue(
            state,
            "{\"protocol\":\"cmux.protocol/2\",\"type\":\"response\","
            "\"id\":\"cpp-request-1\"," +
                fields + "}");

        auto result = client.read(cmux::Operation::session_ping);
        CHECK(!result);
        CHECK_EQ(result.error().code, cmux::ErrorCode::protocol);
        std::lock_guard lock(state->mutex);
        CHECK_EQ(state->outgoing.size(), 1U);
    };

    run("\"ok\":true");
    run(
        "\"ok\":true,\"result\":{},\"error\":{\"code\":\"failed\","
        "\"message\":\"bad\",\"details\":{},\"retryable\":false}");
    run(
        "\"ok\":false,\"result\":{},\"error\":{\"code\":\"failed\","
        "\"message\":\"bad\",\"details\":{},\"retryable\":false}");
    run("\"ok\":true,\"result\":{},\"future\":true");
    run(
        "\"ok\":false,\"error\":{\"code\":\"failed\","
        "\"message\":\"bad\",\"details\":{},\"retryable\":false,"
        "\"future\":true}");
    run(
        "\"ok\":false,\"error\":{\"code\":\"failed\","
        "\"message\":\"bad\",\"retryable\":false}");
}

TEST("layout undo requires and carries typed confirmation details") {
    cmux::UndoLayoutOptions missing_token{
        .confirm_close = true,
        .confirmation_token = std::nullopt,
    };
    auto missing_params = missing_token.to_params();
    CHECK(!missing_params);
    CHECK_EQ(
        missing_params.error().code,
        cmux::ErrorCode::invalid_argument);

    cmux::UndoLayoutOptions oversized{
        .confirmation_token = std::string(129, 'x'),
    };
    CHECK(!oversized.to_params());

    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    enqueue(
        state,
        error_response(
            "cpp-request-1",
            "confirmation.required",
            R"({"confirmation_token":"confirm-9","revision":"9","closes_panes":["pane_0123456789abcdef0123456789abcdef"]})"));
    auto key = cmux::MutationOptions::with_key("confirm-key");
    CHECK(key);
    auto result =
        client.screen(cmux::Selector<cmux::ScreenId>::current())
            .undo_layout(
                {
                    .confirm_close = true,
                    .confirmation_token = "confirm-8",
                },
                std::move(key).value().expecting(8));
    CHECK(!result);
    auto details =
        cmux::decode_confirmation_required_details(result.error());
    CHECK(details);
    CHECK_EQ(
        details.value().confirmation_token,
        std::string("confirm-9"));
    CHECK_EQ(details.value().revision, 9U);
    CHECK_EQ(details.value().closes_panes.size(), 1U);
    CHECK_EQ(
        details.value().closes_panes.front().value(),
        std::string("pane_0123456789abcdef0123456789abcdef"));

    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 1U);
    auto envelope = cmux::Json::parse(state->outgoing.front());
    CHECK(envelope);
    const auto* params =
        envelope.value().find("params")->as_object().value();
    CHECK(params->at("confirm_close").as_bool().value());
    CHECK_EQ(
        params->at("confirmation_token").as_string().value(),
        std::string_view("confirm-8"));
    CHECK_EQ(
        params->at("expected_revision").as_string().value(),
        std::string_view("8"));
}

TEST("indeterminate mutations retain outcome details and never retry") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    enqueue(
        state,
        R"({"protocol":"cmux.protocol/2","type":"response","id":"cpp-request-1","ok":false,"error":{"code":"mutation.indeterminate","message":"external effect may have committed","details":{"idempotency_key":"indeterminate-test-key","operation":"workspace.rename","recovery":"inspect_state_then_retry_with_new_key"},"retryable":false}})");
    auto key = cmux::MutationOptions::with_key("indeterminate-test-key");
    CHECK(key);
    auto result = client.mutate(
        cmux::Operation::workspace_rename,
        {
            {"workspace",
             cmux::Json("ws_0123456789abcdef0123456789abcdef")},
            {"name", cmux::Json("maybe-renamed")},
        },
        std::move(key).value());
    CHECK(!result);
    CHECK_EQ(
        result.error().code,
        cmux::ErrorCode::outcome_uncertain);
    CHECK_EQ(
        result.error().protocol_code,
        std::string("mutation.indeterminate"));
    CHECK_EQ(
        result.error().message,
        std::string("external effect may have committed"));
    CHECK(!result.error().retryable);
    CHECK(result.error().uncertain_mutation != nullptr);
    CHECK_EQ(
        result.error().uncertain_mutation->operation,
        cmux::Operation::workspace_rename);
    CHECK_EQ(
        result.error().uncertain_mutation->idempotency_key,
        std::string("indeterminate-test-key"));
    CHECK(result.error().details != nullptr);
    auto details = result.error().details->as_object();
    CHECK(details);
    CHECK_EQ(details.value()->size(), 3U);
    CHECK_EQ(
        details.value()->at("idempotency_key").as_string().value(),
        std::string_view("indeterminate-test-key"));
    CHECK_EQ(
        details.value()->at("operation").as_string().value(),
        std::string_view("workspace.rename"));
    CHECK_EQ(
        details.value()->at("recovery").as_string().value(),
        std::string_view("inspect_state_then_retry_with_new_key"));

    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 1U);
    CHECK(
        state->outgoing.front().find("indeterminate-test-key") !=
        std::string::npos);
}

TEST("cancellation before send and uncertain mutation outcomes are typed") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    std::stop_source stopped;
    stopped.request_stop();
    cmux::CallOptions canceled;
    canceled.cancel = stopped.get_token();
    auto read = client.read(
        cmux::Operation::machine_list, {}, std::move(canceled));
    CHECK(!read);
    CHECK_EQ(read.error().code, cmux::ErrorCode::canceled);
    {
        std::lock_guard lock(state->mutex);
        CHECK(state->outgoing.empty());
    }

    auto workspace_id = cmux::WorkspaceId::parse(
        "ws_0123456789abcdef0123456789abcdef");
    CHECK(workspace_id);
    auto command = cmux::RunCommand::exact({"true"});
    CHECK(command);
    cmux::RunOptions run(std::move(command).value());
    auto run_key =
        cmux::MutationOptions::with_key("canceled-workspace-run");
    CHECK(run_key);
    cmux::CallOptions canceled_run;
    canceled_run.cancel = stopped.get_token();
    auto workspace_run =
        client.workspace(std::move(workspace_id).value())
            .run(
                std::move(run),
                std::move(run_key).value(),
                std::move(canceled_run));
    CHECK(!workspace_run);
    CHECK_EQ(workspace_run.error().code, cmux::ErrorCode::canceled);
    {
        std::lock_guard lock(state->mutex);
        CHECK(state->outgoing.empty());
    }

    auto key = cmux::MutationOptions::with_key("uncertain-exact-key");
    CHECK(key);
    auto mutation = client.mutate(
        cmux::Operation::workspace_rename,
        {
            {
                "workspace",
                cmux::Json(
                    "ws_0123456789abcdef0123456789abcdef"),
            },
            {"name", cmux::Json("new name")},
        },
        std::move(key).value(),
        cmux::CallOptions::with_timeout(std::chrono::milliseconds(20)));
    CHECK(!mutation);
    CHECK_EQ(
        mutation.error().code,
        cmux::ErrorCode::outcome_uncertain);
    CHECK(!mutation.error().retryable);
    CHECK(mutation.error().uncertain_mutation != nullptr);
    CHECK_EQ(
        mutation.error().uncertain_mutation->operation,
        cmux::Operation::workspace_rename);
    CHECK_EQ(
        mutation.error().uncertain_mutation->idempotency_key,
        std::string("uncertain-exact-key"));
    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 1U);
}

TEST("queued request admission obeys deadline and cancellation without sending") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    std::optional<cmux::Result<cmux::Json>> first_result;
    std::thread first([&] {
        first_result = client.read(cmux::Operation::session_ping);
    });
    wait_for_writes(state, 1);

    auto terminal_id = cmux::TerminalId::parse(
        "term_0123456789abcdef0123456789abcdef");
    CHECK(terminal_id);
    auto terminal = client.terminal(std::move(terminal_id).value());
    auto timed_out = terminal.wait(
        "queued",
        std::nullopt,
        cmux::CallOptions::with_timeout(std::chrono::milliseconds(20)));
    CHECK(!timed_out);
    CHECK_EQ(timed_out.error().code, cmux::ErrorCode::timeout);

    std::stop_source stopped;
    std::atomic<bool> cancel_started{false};
    std::optional<cmux::Result<cmux::TerminalWaitExitResult>> canceled;
    std::thread queued([&] {
        cmux::CallOptions call;
        call.cancel = stopped.get_token();
        cancel_started.store(true, std::memory_order_release);
        canceled = terminal.wait_exit(std::nullopt, std::move(call));
    });
    while (!cancel_started.load(std::memory_order_acquire)) {
        std::this_thread::yield();
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    stopped.request_stop();
    queued.join();
    CHECK(canceled.has_value());
    CHECK(!*canceled);
    CHECK_EQ(canceled->error().code, cmux::ErrorCode::canceled);

    cmux::Json first_request;
    {
        std::lock_guard lock(state->mutex);
        CHECK_EQ(state->outgoing.size(), 1U);
        first_request = cmux::Json::parse(state->outgoing.front()).value();
    }
    enqueue(
        state,
        response(
            std::string(first_request.find("id")->as_string().value()),
            R"({"alive":true,"cursor":{"generation":"g","revision":"1"}})"));
    first.join();
    CHECK(first_result.has_value());
    CHECK(*first_result);
    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 1U);
    CHECK_EQ(state->close_calls, 0U);
}

TEST("queued request retries a failed timed lock attempt before its deadline") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    std::optional<cmux::Result<cmux::Json>> first_result;
    std::thread first([&] {
        first_result = client.read(cmux::Operation::session_ping);
    });
    wait_for_writes(state, 1);

    cmux::detail::simulate_spurious_request_lock_failures(1);
    std::optional<cmux::Result<cmux::Json>> queued_result;
    std::thread queued([&] {
        queued_result = client.read(
            cmux::Operation::session_ping,
            {},
            cmux::CallOptions::with_timeout(std::chrono::seconds(2)));
    });

    const auto observation_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(1);
    while (
        cmux::detail::simulated_request_lock_failures_observed() == 0 &&
        std::chrono::steady_clock::now() < observation_deadline) {
        std::this_thread::yield();
    }
    const bool failure_was_observed =
        cmux::detail::simulated_request_lock_failures_observed() == 1;

    std::string first_id;
    {
        std::lock_guard lock(state->mutex);
        first_id = std::string(
            cmux::Json::parse(state->outgoing.front())
                .value()
                .find("id")
                ->as_string()
                .value());
    }
    enqueue(
        state,
        response(
            first_id,
            R"({"alive":true,"cursor":{"generation":"g","revision":"1"}})"));
    first.join();

    bool queued_was_sent = false;
    std::string queued_id;
    {
        std::unique_lock lock(state->mutex);
        queued_was_sent = state->changed.wait_for(
            lock,
            std::chrono::seconds(1),
            [&] { return state->outgoing.size() >= 2; });
        if (queued_was_sent) {
            queued_id = std::string(
                cmux::Json::parse(state->outgoing.at(1))
                    .value()
                    .find("id")
                    ->as_string()
                    .value());
        }
    }
    if (queued_was_sent) {
        enqueue(
            state,
            response(
                queued_id,
                R"({"alive":true,"cursor":{"generation":"g","revision":"2"}})"));
    }
    queued.join();
    cmux::detail::simulate_spurious_request_lock_failures(0);

    CHECK(failure_was_observed);
    CHECK(first_result.has_value());
    CHECK(*first_result);
    CHECK(queued_was_sent);
    CHECK(queued_result.has_value());
    CHECK(*queued_result);
    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 2U);
    CHECK_EQ(state->close_calls, 0U);
}

TEST("timed out terminal wait cancels once and reuses its connection") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    std::atomic<bool> cancel_route_ok{false};
    std::thread server([state, &cancel_route_ok] {
        wait_for_writes(state, 1);
        cmux::Json wait;
        {
            std::lock_guard lock(state->mutex);
            wait = cmux::Json::parse(state->outgoing.at(0)).value();
        }
        const auto wait_id =
            std::string(wait.find("id")->as_string().value());
        CHECK_EQ(
            wait.find("operation")->as_string().value(),
            std::string_view("terminal.wait"));

        wait_for_writes(state, 2);
        cmux::Json cancel;
        {
            std::lock_guard lock(state->mutex);
            cancel = cmux::Json::parse(state->outgoing.at(1)).value();
        }
        const auto cancel_id =
            std::string(cancel.find("id")->as_string().value());
        const auto* params =
            cancel.find("params")->as_object().value();
        cancel_route_ok.store(
            cancel.find("operation")->as_string().value() ==
                    "request.cancel" &&
                params->size() == 1U &&
                params->at("request_id").as_string().value() == wait_id &&
                cancel.find("idempotency_key") == nullptr,
            std::memory_order_release);
        enqueue(
            state,
            response(cancel_id, R"({"canceled":true})"));

        wait_for_writes(state, 3);
        cmux::Json ping;
        {
            std::lock_guard lock(state->mutex);
            ping = cmux::Json::parse(state->outgoing.at(2)).value();
        }
        CHECK_EQ(
            ping.find("operation")->as_string().value(),
            std::string_view("session.ping"));
        enqueue(
            state,
            response(
                std::string(ping.find("id")->as_string().value()),
                R"({"alive":true,"cursor":{"generation":"g","revision":"1"}})"));
    });

    auto terminal_id = cmux::TerminalId::parse(
        "term_0123456789abcdef0123456789abcdef");
    CHECK(terminal_id);
    auto terminal = client.terminal(std::move(terminal_id).value());
    auto waited = terminal.wait(
        "never",
        std::nullopt,
        cmux::CallOptions::with_timeout(
            std::chrono::milliseconds(20)));
    CHECK(!waited);
    CHECK_EQ(waited.error().code, cmux::ErrorCode::timeout);
    auto ping = client.read(cmux::Operation::session_ping);
    CHECK(ping);
    server.join();
    CHECK(cancel_route_ok.load(std::memory_order_acquire));
    {
        std::lock_guard lock(state->mutex);
        CHECK_EQ(state->outgoing.size(), 3U);
        CHECK_EQ(state->close_calls, 0U);
    }
}

TEST("terminal wait cancel false drains raced completion before reuse") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    std::thread server([state] {
        wait_for_writes(state, 1);
        cmux::Json wait;
        {
            std::lock_guard lock(state->mutex);
            wait = cmux::Json::parse(state->outgoing.at(0)).value();
        }
        const auto wait_id =
            std::string(wait.find("id")->as_string().value());

        wait_for_writes(state, 2);
        cmux::Json cancel;
        {
            std::lock_guard lock(state->mutex);
            cancel = cmux::Json::parse(state->outgoing.at(1)).value();
        }
        {
            std::lock_guard lock(state->mutex);
            state->incoming.push_back(response(
                std::string(cancel.find("id")->as_string().value()),
                R"({"canceled":false})"));
            state->incoming.push_back(response(
                wait_id,
                R"({"matched":true,"text":"raced"})"));
            state->changed.notify_all();
        }

        wait_for_writes(state, 3);
        cmux::Json ping;
        {
            std::lock_guard lock(state->mutex);
            ping = cmux::Json::parse(state->outgoing.at(2)).value();
        }
        CHECK_EQ(
            ping.find("operation")->as_string().value(),
            std::string_view("session.ping"));
        enqueue(
            state,
            response(
                std::string(ping.find("id")->as_string().value()),
                R"({"alive":true,"cursor":{"generation":"g","revision":"2"}})"));
    });

    auto terminal_id = cmux::TerminalId::parse(
        "term_0123456789abcdef0123456789abcdef");
    CHECK(terminal_id);
    auto terminal = client.terminal(std::move(terminal_id).value());
    auto waited = terminal.wait(
        "raced",
        std::nullopt,
        cmux::CallOptions::with_timeout(
            std::chrono::milliseconds(20)));
    CHECK(!waited);
    CHECK_EQ(waited.error().code, cmux::ErrorCode::timeout);
    {
        std::lock_guard lock(state->mutex);
        CHECK(state->incoming.empty());
        CHECK_EQ(state->outgoing.size(), 2U);
    }
    CHECK(client.read(cmux::Operation::session_ping));
    server.join();
    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 3U);
    CHECK_EQ(state->close_calls, 0U);
}

TEST("terminal wait cancel false rejects malformed raced completion") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    std::thread server([state] {
        wait_for_writes(state, 1);
        cmux::Json wait;
        {
            std::lock_guard lock(state->mutex);
            wait = cmux::Json::parse(state->outgoing.at(0)).value();
        }
        const auto wait_id =
            std::string(wait.find("id")->as_string().value());
        wait_for_writes(state, 2);
        cmux::Json cancel;
        {
            std::lock_guard lock(state->mutex);
            cancel = cmux::Json::parse(state->outgoing.at(1)).value();
        }
        {
            std::lock_guard lock(state->mutex);
            state->incoming.push_back(response(
                std::string(cancel.find("id")->as_string().value()),
                R"({"canceled":false})"));
            state->incoming.push_back(response(
                wait_id,
                R"({"matched":true})"));
            state->changed.notify_all();
        }
    });

    auto terminal_id = cmux::TerminalId::parse(
        "term_0123456789abcdef0123456789abcdef");
    CHECK(terminal_id);
    auto waited = client.terminal(std::move(terminal_id).value()).wait(
        "raced",
        std::nullopt,
        cmux::CallOptions::with_timeout(std::chrono::milliseconds(20)));
    CHECK(!waited);
    CHECK_EQ(waited.error().code, cmux::ErrorCode::timeout);
    server.join();
    CHECK(client.closed());
    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 2U);
    CHECK_EQ(state->close_calls, 1U);
}

TEST("wait exit abort is preserved and predispatch abort is wire silent") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    std::thread server([state] {
        wait_for_writes(state, 1);
        cmux::Json wait;
        {
            std::lock_guard lock(state->mutex);
            wait = cmux::Json::parse(state->outgoing.at(0)).value();
        }
        CHECK_EQ(
            wait.find("operation")->as_string().value(),
            std::string_view("terminal.wait_exit"));
        const auto wait_id =
            std::string(wait.find("id")->as_string().value());

        wait_for_writes(state, 2);
        cmux::Json cancel;
        {
            std::lock_guard lock(state->mutex);
            cancel = cmux::Json::parse(state->outgoing.at(1)).value();
        }
        const auto* params =
            cancel.find("params")->as_object().value();
        CHECK_EQ(params->size(), 1U);
        CHECK_EQ(
            params->at("request_id").as_string().value(),
            std::string_view(wait_id));
        enqueue(
            state,
            response(
                std::string(cancel.find("id")->as_string().value()),
                R"({"canceled":true})"));

        wait_for_writes(state, 3);
        cmux::Json ping;
        {
            std::lock_guard lock(state->mutex);
            ping = cmux::Json::parse(state->outgoing.at(2)).value();
        }
        CHECK_EQ(
            ping.find("operation")->as_string().value(),
            std::string_view("session.ping"));
        enqueue(
            state,
            response(
                std::string(ping.find("id")->as_string().value()),
                R"({"alive":true,"cursor":{"generation":"g","revision":"3"}})"));
    });

    auto terminal_id = cmux::TerminalId::parse(
        "term_0123456789abcdef0123456789abcdef");
    CHECK(terminal_id);
    auto terminal = client.terminal(std::move(terminal_id).value());
    std::stop_source stopped;
    std::optional<cmux::Result<cmux::TerminalWaitExitResult>> waited;
    std::thread worker([&] {
        cmux::CallOptions call;
        call.cancel = stopped.get_token();
        waited = terminal.wait_exit(
            std::nullopt,
            std::move(call));
    });
    wait_for_writes(state, 1);
    stopped.request_stop();
    worker.join();
    CHECK(waited.has_value());
    CHECK(!*waited);
    CHECK_EQ(waited->error().code, cmux::ErrorCode::canceled);

    std::stop_source already_stopped;
    already_stopped.request_stop();
    cmux::CallOptions predispatch_call;
    predispatch_call.cancel = already_stopped.get_token();
    auto predispatch = terminal.wait_exit(
        std::nullopt,
        std::move(predispatch_call));
    CHECK(!predispatch);
    CHECK_EQ(
        predispatch.error().code,
        cmux::ErrorCode::canceled);
    {
        std::lock_guard lock(state->mutex);
        CHECK_EQ(state->outgoing.size(), 2U);
    }

    CHECK(client.read(cmux::Operation::session_ping));
    server.join();
    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 3U);
    CHECK_EQ(state->close_calls, 0U);
}

TEST("malformed wait cleanup preserves timeout and fail closes once") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    std::thread server([state] {
        wait_for_writes(state, 2);
        cmux::Json cancel;
        {
            std::lock_guard lock(state->mutex);
            cancel = cmux::Json::parse(state->outgoing.at(1)).value();
        }
        enqueue(
            state,
            response(
                std::string(cancel.find("id")->as_string().value()),
                R"({"canceled":true,"future":true})"));
    });

    auto terminal_id = cmux::TerminalId::parse(
        "term_0123456789abcdef0123456789abcdef");
    CHECK(terminal_id);
    auto waited =
        client.terminal(std::move(terminal_id).value())
            .wait(
                "never",
                std::nullopt,
                cmux::CallOptions::with_timeout(
                    std::chrono::milliseconds(20)));
    CHECK(!waited);
    CHECK_EQ(waited.error().code, cmux::ErrorCode::timeout);
    server.join();
    CHECK(client.closed());
    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 2U);
    CHECK_EQ(state->close_calls, 1U);
}

TEST("terminal lifecycle and wait-exit unions decode strictly") {
    auto running = cmux::detail::decode_value<cmux::TerminalSnapshot>(
        cmux::Json::parse(
            R"({"id":"term_0123456789abcdef0123456789abcdef","tab_ids":["tab_0123456789abcdef0123456789abcdef"],"title":"shell","cols":80,"rows":24,"running":true,"lifecycle":"running"})")
            .value());
    CHECK(running);
    CHECK_EQ(
        running.value().lifecycle,
        cmux::TerminalLifecycle::running);
    CHECK(!running.value().exit.has_value());

    auto projected = cmux::detail::decode_value<cmux::TerminalSnapshot>(
        cmux::Json::parse(
            R"({"id":"term_0123456789abcdef0123456789abcdef","tab_ids":["tab_0123456789abcdef0123456789abcdef","tab_11111111111111111111111111111111"],"title":"shell","cols":80,"rows":24,"running":true,"lifecycle":"running"})")
            .value());
    CHECK(projected);
    CHECK_EQ(projected.value().tab_ids.size(), 2U);

    auto missing_attached_views = cmux::detail::decode_value<cmux::TerminalSnapshot>(
        cmux::Json::parse(
            R"({"id":"term_0123456789abcdef0123456789abcdef","title":"legacy","cols":80,"rows":24,"running":true,"lifecycle":"running"})")
            .value());
    CHECK(!missing_attached_views);
    CHECK_EQ(missing_attached_views.error().code, cmux::ErrorCode::decode);

    auto legacy_attached = cmux::detail::decode_value<cmux::TerminalSnapshot>(
        cmux::Json::parse(
            R"({"id":"term_0123456789abcdef0123456789abcdef","tab_id":"tab_0123456789abcdef0123456789abcdef","title":"legacy","cols":80,"rows":24,"running":true,"lifecycle":"running"})")
            .value());
    CHECK(legacy_attached);
    CHECK_EQ(legacy_attached.value().tab_ids.size(), 1U);

    auto legacy_detached = cmux::detail::decode_value<cmux::TerminalSnapshot>(
        cmux::Json::parse(
            R"({"id":"term_0123456789abcdef0123456789abcdef","tab_id":null,"title":"legacy","cols":80,"rows":24,"running":true,"lifecycle":"running"})")
            .value());
    CHECK(legacy_detached);
    CHECK(legacy_detached.value().tab_ids.empty());

    auto consistent_dual = cmux::detail::decode_value<cmux::TerminalSnapshot>(
        cmux::Json::parse(
            R"({"id":"term_0123456789abcdef0123456789abcdef","tab_id":"tab_0123456789abcdef0123456789abcdef","tab_ids":["tab_0123456789abcdef0123456789abcdef"],"title":"legacy","cols":80,"rows":24,"running":true,"lifecycle":"running"})")
            .value());
    CHECK(consistent_dual);

    auto inconsistent_dual = cmux::detail::decode_value<cmux::TerminalSnapshot>(
        cmux::Json::parse(
            R"({"id":"term_0123456789abcdef0123456789abcdef","tab_id":"tab_0123456789abcdef0123456789abcdef","tab_ids":[],"title":"legacy","cols":80,"rows":24,"running":true,"lifecycle":"running"})")
            .value());
    CHECK(!inconsistent_dual);
    CHECK_EQ(inconsistent_dual.error().code, cmux::ErrorCode::decode);

    auto exited = cmux::detail::decode_value<cmux::TerminalSnapshot>(
        cmux::Json::parse(
            R"({"id":"term_0123456789abcdef0123456789abcdef","tab_ids":[],"title":"done","cols":80,"rows":24,"running":false,"lifecycle":"exited","exit":{"outcome":{"kind":"exit","code":0},"exited_at":"123","revision":"9"}})")
            .value());
    CHECK(exited);
    CHECK(exited.value().exit.has_value());
    CHECK(std::holds_alternative<cmux::TerminalExitCode>(
        exited.value().exit->outcome));

    auto inconsistent =
        cmux::detail::decode_value<cmux::TerminalSnapshot>(
            cmux::Json::parse(
                R"({"id":"term_0123456789abcdef0123456789abcdef","tab_ids":["tab_0123456789abcdef0123456789abcdef"],"title":"bad","cols":80,"rows":24,"running":true,"lifecycle":"launching"})")
                .value());
    CHECK(!inconsistent);
    CHECK_EQ(inconsistent.error().code, cmux::ErrorCode::decode);

    auto pending =
        cmux::detail::decode_value<cmux::TerminalWaitExitResult>(
            cmux::Json::parse(
                R"({"state":"pending","terminal_id":"term_0123456789abcdef0123456789abcdef","lifecycle":"launching","revision":"4"})")
                .value());
    CHECK(pending);
    CHECK(std::holds_alternative<cmux::TerminalWaitExitPending>(
        pending.value()));
}

TEST("browser attachment frames require nullable decimal pointer guards") {
    auto guarded = cmux::detail::decode_browser_attachment(
        cmux::Json::parse(
            R"({"kind":"frame","mime_type":"image/png","data_base64":"AA==","width_px":1280,"height_px":720,"pointer_frame_seq":"18446744073709551615"})")
            .value(),
        std::nullopt);
    CHECK(guarded);
    const auto* guarded_frame =
        std::get_if<cmux::BrowserAttachFrame>(&guarded.value());
    CHECK(guarded_frame != nullptr);
    CHECK(guarded_frame->pointer_frame_seq.has_value());
    CHECK_EQ(
        *guarded_frame->pointer_frame_seq,
        std::numeric_limits<std::uint64_t>::max());

    auto unguarded = cmux::detail::decode_browser_attachment(
        cmux::Json::parse(
            R"({"kind":"frame","mime_type":"image/jpeg","data_base64":"AA==","width_px":1,"height_px":1,"pointer_frame_seq":null})")
            .value(),
        std::nullopt);
    CHECK(unguarded);
    const auto* unguarded_frame =
        std::get_if<cmux::BrowserAttachFrame>(&unguarded.value());
    CHECK(unguarded_frame != nullptr);
    CHECK(!unguarded_frame->pointer_frame_seq.has_value());

    auto missing = cmux::detail::decode_browser_attachment(
        cmux::Json::parse(
            R"({"kind":"frame","mime_type":"image/png","data_base64":"AA==","width_px":1,"height_px":1})")
            .value(),
        std::nullopt);
    CHECK(!missing);
    CHECK_EQ(missing.error().code, cmux::ErrorCode::decode);
    CHECK(
        missing.error().message.find("pointer_frame_seq") !=
        std::string::npos);

    auto numeric = cmux::detail::decode_browser_attachment(
        cmux::Json::parse(
            R"({"kind":"frame","mime_type":"image/png","data_base64":"AA==","width_px":1,"height_px":1,"pointer_frame_seq":42})")
            .value(),
        std::nullopt);
    CHECK(!numeric);
    CHECK_EQ(numeric.error().code, cmux::ErrorCode::decode);
    CHECK(
        numeric.error().message.find("canonical decimal string") !=
        std::string::npos);
}

TEST("browser pointer inputs require and exactly encode frame guards") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    enqueue(
        state,
        response(
            "cpp-request-1",
            R"({"value":{},"generation":"g","revision":"1","replayed":false})"));
    enqueue(
        state,
        response(
            "cpp-request-2",
            R"({"value":{},"generation":"g","revision":"2","replayed":false})"));

    auto browser_id = cmux::BrowserId::parse(
        "browser_0123456789abcdef0123456789abcdef");
    CHECK(browser_id);
    auto browser = client.browser(std::move(browser_id).value());
    auto mouse_key = cmux::MutationOptions::with_key("browser-mouse-guard");
    auto wheel_key = cmux::MutationOptions::with_key("browser-wheel-guard");
    CHECK(mouse_key);
    CHECK(wheel_key);
    constexpr auto pointer_frame_seq =
        std::numeric_limits<std::uint64_t>::max();

    auto mouse = browser.mouse(
        {
            {"kind", cmux::Json("move")},
            {"x_px", cmux::Json(12.5)},
            {"y_px", cmux::Json(34.5)},
            {"pointer_frame_seq", cmux::Json("caller-value")},
        },
        pointer_frame_seq,
        std::move(mouse_key).value());
    CHECK(mouse);
    auto wheel = browser.wheel(
        1.25,
        -2.5,
        640.5,
        360.25,
        pointer_frame_seq,
        std::move(wheel_key).value());
    CHECK(wheel);

    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 2U);
    auto mouse_envelope = cmux::Json::parse(state->outgoing.at(0));
    auto wheel_envelope = cmux::Json::parse(state->outgoing.at(1));
    CHECK(mouse_envelope);
    CHECK(wheel_envelope);
    CHECK_EQ(
        mouse_envelope.value().find("operation")->as_string().value(),
        std::string_view("browser.input.mouse"));
    CHECK_EQ(
        wheel_envelope.value().find("operation")->as_string().value(),
        std::string_view("browser.input.wheel"));
    const auto* mouse_params =
        mouse_envelope.value().find("params")->as_object().value();
    const auto* wheel_params =
        wheel_envelope.value().find("params")->as_object().value();
    CHECK_EQ(
        mouse_params->at("pointer_frame_seq").as_string().value(),
        std::string_view("18446744073709551615"));
    CHECK_EQ(
        wheel_params->at("pointer_frame_seq").as_string().value(),
        std::string_view("18446744073709551615"));
    CHECK(!mouse_params->at("pointer_frame_seq").as_uint64());
    CHECK(!wheel_params->at("pointer_frame_seq").as_uint64());
    CHECK_EQ(
        mouse_params->at("kind").as_string().value(),
        std::string_view("move"));
    CHECK_EQ(wheel_params->at("delta_x").as_double().value(), 1.25);
    CHECK_EQ(wheel_params->at("delta_y").as_double().value(), -2.5);
    CHECK_EQ(wheel_params->at("x_px").as_double().value(), 640.5);
    CHECK_EQ(wheel_params->at("y_px").as_double().value(), 360.25);
}

TEST("browser wheel rejects non-finite targeting before IO") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    auto browser_id = cmux::BrowserId::parse(
        "browser_0123456789abcdef0123456789abcdef");
    CHECK(browser_id);
    auto key = cmux::MutationOptions::with_key("invalid-browser-wheel");
    CHECK(key);
    auto result =
        client.browser(std::move(browser_id).value())
            .wheel(
                0.0,
                std::numeric_limits<double>::infinity(),
                10.0,
                20.0,
                1,
                std::move(key).value());
    CHECK(!result);
    CHECK_EQ(result.error().code, cmux::ErrorCode::invalid_argument);
    std::lock_guard lock(state->mutex);
    CHECK(state->outgoing.empty());
}

TEST("client metadata preserves omitted set-empty and clear states") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    enqueue(
        state,
        response(
            "cpp-request-1",
            R"({"id":"client_0123456789abcdef0123456789abcdef","session_id":"session_00000000000000000000000000000000","name":"","client_kind":null,"transport":"unix","connected_seconds":"0","attached_terminal_ids":[],"sizes":[],"self":true})"));
    auto id = cmux::ConnectedClientId::parse(
        "client_0123456789abcdef0123456789abcdef");
    CHECK(id);
    auto result = client.connected_client(std::move(id).value())
                      .update_metadata({
                          .name = cmux::OptionalStringUpdate::set(""),
                          .kind = cmux::OptionalStringUpdate::clear(),
                      });
    CHECK(result);
    CHECK_EQ(result.value().transport, cmux::ClientTransport::unix_socket);
    std::lock_guard lock(state->mutex);
    auto envelope = cmux::Json::parse(state->outgoing.front());
    CHECK(envelope);
    CHECK(envelope.value().find("idempotency_key") == nullptr);
    const auto* params =
        envelope.value().find("params")->as_object().value();
    CHECK_EQ(
        params->at("name").as_string().value(),
        std::string_view(""));
    CHECK(params->at("kind").is_null());
}

TEST("renderer grants never format capabilities") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    enqueue(
        state,
        response(
            "cpp-request-1",
            R"({"endpoint":"/tmp/renderer.sock","terminal_id":"term_0123456789abcdef0123456789abcdef","token":"renderer-secret","rights":["read","input"],"ttl_ms":5000})"));
    auto id = cmux::TerminalId::parse(
        "term_0123456789abcdef0123456789abcdef");
    CHECK(id);
    auto grant = client.terminal(std::move(id).value()).renderer_grant();
    CHECK(grant);
    CHECK_EQ(grant.value().endpoint, std::string("/tmp/renderer.sock"));
    CHECK_EQ(grant.value().ttl_ms, 5000U);
    CHECK_EQ(grant.value().rights.size(), 2U);
    CHECK_EQ(grant.value().token.reveal(), std::string("renderer-secret"));
    std::ostringstream grant_output;
    grant_output << grant.value();
    CHECK(grant_output.str().find("renderer-secret") == std::string::npos);
    CHECK(grant_output.str().find("[REDACTED]") != std::string::npos);
}

TEST("constructing copying and dropping selector handles performs no IO") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    auto id = cmux::WorkspaceId::parse(
        "ws_0123456789abcdef0123456789abcdef");
    CHECK(id);
    {
        auto workspace = client.workspace(std::move(id).value());
        auto copied = workspace;
        CHECK_EQ(copied.id().value(), workspace.id().value());
        CHECK(copied.selected_id().has_value());

        auto terminal =
            client.machine(
                      cmux::Selector<cmux::MachineId>::exact_name("remote"))
                .session(cmux::Selector<cmux::SessionId>::current())
                .workspace(
                    cmux::Selector<cmux::WorkspaceId>::exact_name(
                        "duplicate"))
                .screen(cmux::Selector<cmux::ScreenId>::current())
                .pane(cmux::Selector<cmux::PaneId>::exact_name("editor"))
                .tab(cmux::Selector<cmux::TabId>::current())
                .terminal(
                    cmux::Selector<cmux::TerminalId>::exact_name("shell"));
        auto terminal_copy = terminal;
        CHECK_EQ(
            terminal_copy.selector().kind(),
            cmux::Selector<cmux::TerminalId>::Kind::name);
        CHECK_EQ(terminal_copy.selector().value(), std::string("shell"));
        CHECK(!terminal_copy.selected_id().has_value());

        auto browser =
            client.tab(cmux::Selector<cmux::TabId>::current())
                .browser(cmux::Selector<cmux::BrowserId>::current());
        CHECK_EQ(
            browser.selector().kind(),
            cmux::Selector<cmux::BrowserId>::Kind::current);
    }
    std::lock_guard lock(state->mutex);
    CHECK(state->outgoing.empty());
}

TEST("duplicate name selectors preserve ambiguity candidates and route") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    enqueue(
        state,
        error_response(
            "cpp-request-1",
            "selector.ambiguous",
            R"({"candidates":["ws_11111111111111111111111111111111","ws_22222222222222222222222222222222"]})"));
    auto result =
        client.session(cmux::Selector<cmux::SessionId>::current())
            .workspace(
                cmux::Selector<cmux::WorkspaceId>::exact_name("duplicate"))
            .rename("must-not-apply");
    CHECK(!result);
    CHECK_EQ(
        result.error().protocol_code,
        std::string("selector.ambiguous"));
    CHECK(result.error().details != nullptr);
    const auto* candidates =
        result.error().details->find("candidates")->as_array().value();
    CHECK_EQ(candidates->size(), 2U);

    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 1U);
    auto envelope = cmux::Json::parse(state->outgoing.front());
    CHECK(envelope);
    const auto* params =
        envelope.value().find("params")->as_object().value();
    CHECK_EQ(
        params->at("machine").as_string().value(),
        std::string_view("current"));
    CHECK_EQ(
        params->at("session").as_string().value(),
        std::string_view("current"));
    CHECK_EQ(
        params->at("workspace").as_string().value(),
        std::string_view("name:duplicate"));
    CHECK_EQ(
        params->at("name").as_string().value(),
        std::string_view("must-not-apply"));
}

TEST("nested selectors send the complete route for wrong-parent checks") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    enqueue(
        state,
        error_response("cpp-request-1", "selector.wrong_parent"));
    auto result =
        client.machine(
                  cmux::Selector<cmux::MachineId>::exact_name("edge"))
            .session(
                cmux::Selector<cmux::SessionId>::exact_name("development"))
            .workspace(
                cmux::Selector<cmux::WorkspaceId>::exact_name("parent-a"))
            .screen(
                cmux::Selector<cmux::ScreenId>::exact_name(
                    "screen-under-parent-b"))
            .pane(cmux::Selector<cmux::PaneId>::current())
            .tab(cmux::Selector<cmux::TabId>::exact_name("logs"))
            .terminal(cmux::Selector<cmux::TerminalId>::current())
            .read_screen();
    CHECK(!result);
    CHECK_EQ(
        result.error().protocol_code,
        std::string("selector.wrong_parent"));

    std::lock_guard lock(state->mutex);
    auto envelope = cmux::Json::parse(state->outgoing.front());
    CHECK(envelope);
    const auto* params =
        envelope.value().find("params")->as_object().value();
    CHECK_EQ(
        params->at("machine").as_string().value(),
        std::string_view("name:edge"));
    CHECK_EQ(
        params->at("session").as_string().value(),
        std::string_view("name:development"));
    CHECK_EQ(
        params->at("workspace").as_string().value(),
        std::string_view("name:parent-a"));
    CHECK_EQ(
        params->at("screen").as_string().value(),
        std::string_view("name:screen-under-parent-b"));
    CHECK_EQ(
        params->at("pane").as_string().value(),
        std::string_view("current"));
    CHECK_EQ(
        params->at("tab").as_string().value(),
        std::string_view("name:logs"));
    CHECK_EQ(
        params->at("terminal").as_string().value(),
        std::string_view("current"));
}

TEST("direct opaque nested IDs remain globally addressable") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    constexpr std::string_view pane_value =
        "pane_0123456789abcdef0123456789abcdef";
    enqueue(
        state,
        response(
            "cpp-request-1",
            R"({"id":"pane_0123456789abcdef0123456789abcdef","screen_id":"screen_00000000000000000000000000000000","name":"detached","focused":false,"zoomed":false})"));
    auto pane_id = cmux::PaneId::parse(pane_value);
    CHECK(pane_id);
    auto refreshed = client.pane(std::move(pane_id).value()).refresh();
    CHECK(refreshed);
    CHECK_EQ(refreshed.value().id.value(), std::string(pane_value));

    std::lock_guard lock(state->mutex);
    auto envelope = cmux::Json::parse(state->outgoing.front());
    CHECK(envelope);
    const auto* params =
        envelope.value().find("params")->as_object().value();
    CHECK_EQ(
        params->at("pane").as_string().value(),
        pane_value);
    CHECK(!params->contains("workspace"));
    CHECK(!params->contains("screen"));
}

TEST("direct current selectors synthesize missing contiguous ancestors") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    enqueue(
        state,
        response(
            "cpp-request-1",
            R"({"text":"","cols":80,"rows":24,"cursor_row":0,"cursor_col":0,"cursor_visible":true})"));
    auto result =
        client.terminal(cmux::Selector<cmux::TerminalId>::current())
            .read_screen();
    CHECK(result);

    std::lock_guard lock(state->mutex);
    auto envelope = cmux::Json::parse(state->outgoing.front());
    CHECK(envelope);
    const auto* params =
        envelope.value().find("params")->as_object().value();
    CHECK_EQ(
        params->at("workspace").as_string().value(),
        std::string_view("current"));
    CHECK_EQ(
        params->at("screen").as_string().value(),
        std::string_view("current"));
    CHECK_EQ(
        params->at("pane").as_string().value(),
        std::string_view("current"));
    CHECK_EQ(
        params->at("tab").as_string().value(),
        std::string_view("current"));
    CHECK_EQ(
        params->at("terminal").as_string().value(),
        std::string_view("current"));
}

TEST("acknowledged stream has no implicit idle deadline") {
    auto control = std::make_shared<FakeState>();
    auto stream_state = std::make_shared<FakeState>();
    constexpr auto client_timeout = std::chrono::milliseconds(20);
    constexpr auto open_timeout = std::chrono::milliseconds(200);
    constexpr std::size_t idle_timeouts = 11;
    static_assert(client_timeout * idle_timeouts > open_timeout);
    auto client = client_for(control, stream_state, client_timeout);

    std::jthread server([stream_state] {
        wait_for_writes(stream_state, 1);
        cmux::Json open;
        {
            std::lock_guard lock(stream_state->mutex);
            open =
                cmux::Json::parse(stream_state->outgoing.at(0)).value();
        }
        const auto request_id =
            std::string(open.find("id")->as_string().value());
        const auto* params = open.find("params")->as_object().value();
        const auto stream_id =
            std::string(params->at("stream_id").as_string().value());
        enqueue(
            stream_state,
            stream_open_response(request_id, stream_id));

        wait_for_receive_timeouts(stream_state, idle_timeouts);
        enqueue(
            stream_state,
            "{\"protocol\":\"cmux.protocol/2\",\"type\":\"stream_item\","
            "\"stream_id\":\"" +
                stream_id +
                "\",\"sequence\":\"1\",\"cursor\":{"
                "\"generation\":\"g\",\"revision\":\"1\"},"
                "\"item\":{\"kind\":\"future.delayed\",\"ready\":true}}");
    });

    auto stream = client.open_session_events(
        {},
        cmux::CallOptions::with_timeout(open_timeout));
    CHECK(stream);
    CHECK(!stream.value().closed());
    auto item = stream.value().next();
    CHECK(item);
    CHECK(item.value().has_value());
    CHECK_EQ(item.value()->sequence, 1U);
    const auto* unknown =
        std::get_if<cmux::Unknown>(&item.value()->value);
    CHECK(unknown != nullptr);
    CHECK_EQ(unknown->kind, std::string("future.delayed"));
    CHECK(unknown->raw.find("ready") != nullptr);
    CHECK(!stream.value().closed());
    std::lock_guard lock(stream_state->mutex);
    CHECK(stream_state->receive_timeouts >= idle_timeouts);
}

TEST("framing-uncertain control send failure closes the client") {
    auto control = std::make_shared<FakeState>();
    auto stream_state = std::make_shared<FakeState>();
    control->fail_send_call = 1U;
    control->record_failed_send = true;
    auto client = client_for(control, stream_state);

    auto first = client.read(cmux::Operation::session_ping);
    CHECK(!first);
    CHECK_EQ(first.error().code, cmux::ErrorCode::connection);
    CHECK_EQ(
        first.error().message,
        std::string("synthetic framing-uncertain send failure"));
    CHECK(client.closed());
    auto repeated = client.read(cmux::Operation::session_ping);
    CHECK(!repeated);
    CHECK_EQ(repeated.error().code, cmux::ErrorCode::closed);
    std::lock_guard lock(control->mutex);
    CHECK_EQ(control->outgoing.size(), 1U);
    CHECK_EQ(control->close_calls, 1U);
}

TEST("failed stream opens close the dedicated transport without cancellation") {
    {
        auto control = std::make_shared<FakeState>();
        auto stream_state = std::make_shared<FakeState>();
        auto client = client_for(control, stream_state);
        std::stop_source stopped;
        stopped.request_stop();
        cmux::CallOptions call;
        call.cancel = stopped.get_token();

        auto opened = client.open_session_events({}, std::move(call));
        CHECK(!opened);
        CHECK_EQ(opened.error().code, cmux::ErrorCode::canceled);
        std::lock_guard lock(stream_state->mutex);
        CHECK(stream_state->closed);
        CHECK_EQ(stream_state->close_calls, 1U);
        CHECK(stream_state->outgoing.empty());
    }

    {
        auto control = std::make_shared<FakeState>();
        auto stream_state = std::make_shared<FakeState>();
        stream_state->fail_send_call = 1U;
        stream_state->record_failed_send = true;
        auto client = client_for(control, stream_state);

        auto opened = client.open_session_events();
        CHECK(!opened);
        CHECK_EQ(opened.error().code, cmux::ErrorCode::connection);
        CHECK_EQ(
            opened.error().message,
            std::string("synthetic framing-uncertain send failure"));
        std::lock_guard lock(stream_state->mutex);
        CHECK(stream_state->closed);
        CHECK_EQ(stream_state->close_calls, 1U);
        CHECK_EQ(stream_state->outgoing.size(), 1U);
    }

    {
        auto control = std::make_shared<FakeState>();
        auto stream_state = std::make_shared<FakeState>();
        auto client = client_for(control, stream_state);
        std::thread server([stream_state] {
            wait_for_writes(stream_state, 1);
            cmux::Json open;
            {
                std::lock_guard lock(stream_state->mutex);
                open = cmux::Json::parse(
                           stream_state->outgoing.front())
                           .value();
            }
            const auto request_id =
                std::string(open.find("id")->as_string().value());
            enqueue(
                stream_state,
                error_response(request_id, "session.not_found"));
        });

        auto opened = client.open_session_events();
        CHECK(!opened);
        CHECK_EQ(opened.error().code, cmux::ErrorCode::command);
        CHECK_EQ(
            opened.error().protocol_code,
            std::string("session.not_found"));
        server.join();
        std::lock_guard lock(stream_state->mutex);
        CHECK(stream_state->closed);
        CHECK_EQ(stream_state->close_calls, 1U);
        CHECK_EQ(stream_state->outgoing.size(), 1U);
    }

    {
        auto control = std::make_shared<FakeState>();
        auto stream_state = std::make_shared<FakeState>();
        auto client = client_for(control, stream_state);
        std::thread server([stream_state] {
            wait_for_writes(stream_state, 1);
            cmux::Json open;
            {
                std::lock_guard lock(stream_state->mutex);
                open = cmux::Json::parse(
                           stream_state->outgoing.front())
                           .value();
            }
            const auto request_id =
                std::string(open.find("id")->as_string().value());
            const auto* params =
                open.find("params")->as_object().value();
            const auto stream_id = std::string(
                params->at("stream_id").as_string().value());
            enqueue(
                stream_state,
                "{\"protocol\":\"cmux.protocol/2\",\"type\":\"response\","
                "\"id\":\"" +
                    request_id +
                    "\",\"ok\":true,\"result\":{\"stream_id\":\"" +
                    stream_id + "\"},\"future\":true}");
        });

        auto opened = client.open_session_events();
        CHECK(!opened);
        CHECK_EQ(opened.error().code, cmux::ErrorCode::protocol);
        server.join();
        std::lock_guard lock(stream_state->mutex);
        CHECK(stream_state->closed);
        CHECK_EQ(stream_state->close_calls, 1U);
        CHECK_EQ(stream_state->outgoing.size(), 1U);
    }

    {
        auto control = std::make_shared<FakeState>();
        auto stream_state = std::make_shared<FakeState>();
        auto client = client_for(control, stream_state);
        std::thread server([stream_state] {
            wait_for_writes(stream_state, 1);
            cmux::Json open;
            {
                std::lock_guard lock(stream_state->mutex);
                open = cmux::Json::parse(
                           stream_state->outgoing.front())
                           .value();
            }
            const auto request_id =
                std::string(open.find("id")->as_string().value());
            enqueue(
                stream_state,
                stream_open_response(
                    request_id,
                    "stream_ffffffffffffffffffffffffffffffff"));
        });

        auto opened = client.open_session_events();
        CHECK(!opened);
        CHECK_EQ(opened.error().code, cmux::ErrorCode::protocol);
        server.join();
        std::lock_guard lock(stream_state->mutex);
        CHECK(stream_state->closed);
        CHECK_EQ(stream_state->close_calls, 1U);
        CHECK_EQ(stream_state->outgoing.size(), 1U);
    }
}

TEST("typed streams preserve unknown items and cancel deterministically") {
    auto control = std::make_shared<FakeState>();
    auto stream_state = std::make_shared<FakeState>();
    auto client = client_for(control, stream_state);
    std::atomic<bool> open_route_ok{false};
    std::atomic<bool> cancel_route_ok{false};

    std::thread server([stream_state, &open_route_ok, &cancel_route_ok] {
        wait_for_writes(stream_state, 1);
        cmux::Json open;
        {
            std::lock_guard lock(stream_state->mutex);
            open =
                cmux::Json::parse(stream_state->outgoing.at(0)).value();
        }
        const auto request_id =
            std::string(open.find("id")->as_string().value());
        const auto* params = open.find("params")->as_object().value();
        const auto stream_id =
            std::string(params->at("stream_id").as_string().value());
        open_route_ok.store(
            params->at("machine").as_string().value() == "current" &&
                params->at("session").as_string().value() ==
                    "session_0123456789abcdef0123456789abcdef",
            std::memory_order_release);
        enqueue(
            stream_state,
            "{\"protocol\":\"cmux.protocol/2\",\"type\":\"stream_item\","
            "\"stream_id\":\"" +
                stream_id +
                "\",\"sequence\":\"1\",\"cursor\":{\"generation\":\"g\","
                "\"revision\":\"9\"},\"item\":{\"kind\":\"future.event\","
                "\"payload\":{\"x\":1},\"future\":true}}");
        enqueue(
            stream_state,
            stream_open_response(request_id, stream_id));

        wait_for_writes(stream_state, 2);
        cmux::Json cancel;
        {
            std::lock_guard lock(stream_state->mutex);
            cancel =
                cmux::Json::parse(stream_state->outgoing.at(1)).value();
        }
        const auto cancel_id =
            std::string(cancel.find("id")->as_string().value());
        const auto* cancel_params =
            cancel.find("params")->as_object().value();
        cancel_route_ok.store(
            cancel_params->at("machine").as_string().value() == "current" &&
                cancel_params->at("session").as_string().value() ==
                    "session_0123456789abcdef0123456789abcdef" &&
                cancel_params->at("stream").as_string().value() == stream_id &&
                cancel_params->find("stream_id") == cancel_params->end(),
            std::memory_order_release);
        enqueue(
            stream_state,
            "{\"protocol\":\"cmux.protocol/2\",\"type\":\"stream_end\","
            "\"stream_id\":\"" +
                stream_id +
                "\",\"reason\":\"canceled\",\"cursor\":{\"generation\":\"g\","
                "\"revision\":\"9\"}}");
        enqueue(stream_state, response(cancel_id));
    });

    auto session_id = cmux::SessionId::parse(
        "session_0123456789abcdef0123456789abcdef");
    CHECK(session_id);
    auto stream = client.session(std::move(session_id).value()).events();
    CHECK(stream);
    auto item = stream.value().next();
    CHECK(item);
    CHECK(item.value().has_value());
    CHECK_EQ(item.value()->sequence, 1U);
    const auto* unknown =
        std::get_if<cmux::Unknown>(&item.value()->value);
    CHECK(unknown != nullptr);
    CHECK_EQ(unknown->kind, std::string("future.event"));
    CHECK(unknown->raw.find("future") != nullptr);
    CHECK(unknown->raw.find("payload") != nullptr);

    auto ended = stream.value().cancel();
    CHECK(ended);
    CHECK_EQ(ended.value().reason, cmux::StreamEndReason::canceled);
    CHECK(stream.value().closed());
    server.join();
    CHECK(open_route_ok.load(std::memory_order_acquire));
    CHECK(cancel_route_ok.load(std::memory_order_acquire));
}

TEST("stream cancellation is one-shot and fail-closes uncertain outcomes") {
    {
        auto control = std::make_shared<FakeState>();
        auto stream_state = std::make_shared<FakeState>();
        stream_state->fail_send_call = 2U;
        stream_state->record_failed_send = true;
        auto client = client_for(control, stream_state);
        std::thread server([stream_state] {
            wait_for_writes(stream_state, 1);
            cmux::Json open;
            {
                std::lock_guard lock(stream_state->mutex);
                open = cmux::Json::parse(
                           stream_state->outgoing.front())
                           .value();
            }
            const auto request_id =
                std::string(open.find("id")->as_string().value());
            const auto* params =
                open.find("params")->as_object().value();
            const auto stream_id = std::string(
                params->at("stream_id").as_string().value());
            enqueue(
                stream_state,
                stream_open_response(request_id, stream_id));
        });

        auto stream = client.open_session_events();
        CHECK(stream);
        server.join();
        auto first = stream.value().cancel();
        CHECK(!first);
        CHECK_EQ(first.error().code, cmux::ErrorCode::connection);
        CHECK_EQ(
            first.error().message,
            std::string("synthetic framing-uncertain send failure"));
        auto repeated = stream.value().cancel();
        CHECK(!repeated);
        CHECK_EQ(repeated.error().code, first.error().code);
        CHECK_EQ(repeated.error().message, first.error().message);
        CHECK(stream.value().closed());
        std::lock_guard lock(stream_state->mutex);
        CHECK_EQ(stream_state->outgoing.size(), 2U);
        CHECK_EQ(stream_state->close_calls, 1U);
    }

    {
        auto control = std::make_shared<FakeState>();
        auto stream_state = std::make_shared<FakeState>();
        auto client = client_for(control, stream_state);
        std::thread server([stream_state] {
            wait_for_writes(stream_state, 1);
            cmux::Json open;
            {
                std::lock_guard lock(stream_state->mutex);
                open = cmux::Json::parse(
                           stream_state->outgoing.front())
                           .value();
            }
            const auto request_id =
                std::string(open.find("id")->as_string().value());
            const auto* params =
                open.find("params")->as_object().value();
            const auto stream_id = std::string(
                params->at("stream_id").as_string().value());
            enqueue(
                stream_state,
                stream_open_response(request_id, stream_id));

            wait_for_writes(stream_state, 2);
            cmux::Json cancel;
            {
                std::lock_guard lock(stream_state->mutex);
                cancel = cmux::Json::parse(
                             stream_state->outgoing.at(1))
                             .value();
            }
            const auto cancel_id =
                std::string(cancel.find("id")->as_string().value());
            enqueue(
                stream_state,
                response(cancel_id, R"({"unexpected":true})"));
        });

        auto stream = client.open_session_events();
        CHECK(stream);
        auto first = stream.value().cancel();
        CHECK(!first);
        CHECK_EQ(first.error().code, cmux::ErrorCode::decode);
        auto repeated = stream.value().cancel();
        CHECK(!repeated);
        CHECK_EQ(repeated.error().code, first.error().code);
        CHECK_EQ(repeated.error().message, first.error().message);
        CHECK(stream.value().closed());
        server.join();
        std::lock_guard lock(stream_state->mutex);
        CHECK_EQ(stream_state->outgoing.size(), 2U);
        CHECK_EQ(stream_state->close_calls, 1U);
    }

    {
        auto control = std::make_shared<FakeState>();
        auto stream_state = std::make_shared<FakeState>();
        auto client = client_for(control, stream_state);
        std::thread server([stream_state] {
            wait_for_writes(stream_state, 1);
            cmux::Json open;
            {
                std::lock_guard lock(stream_state->mutex);
                open = cmux::Json::parse(
                           stream_state->outgoing.front())
                           .value();
            }
            const auto request_id =
                std::string(open.find("id")->as_string().value());
            const auto* params =
                open.find("params")->as_object().value();
            const auto stream_id = std::string(
                params->at("stream_id").as_string().value());
            enqueue(
                stream_state,
                stream_open_response(request_id, stream_id));

            wait_for_writes(stream_state, 2);
            cmux::Json cancel;
            {
                std::lock_guard lock(stream_state->mutex);
                cancel = cmux::Json::parse(
                             stream_state->outgoing.at(1))
                             .value();
            }
            const auto cancel_id =
                std::string(cancel.find("id")->as_string().value());
            enqueue(
                stream_state,
                error_response(cancel_id, "operation.failed"));
        });

        auto stream = client.open_session_events();
        CHECK(stream);
        auto first = stream.value().cancel();
        CHECK(!first);
        CHECK_EQ(first.error().code, cmux::ErrorCode::command);
        CHECK_EQ(
            first.error().protocol_code,
            std::string("operation.failed"));
        auto repeated = stream.value().cancel();
        CHECK(!repeated);
        CHECK_EQ(repeated.error().code, first.error().code);
        CHECK_EQ(
            repeated.error().protocol_code,
            first.error().protocol_code);
        CHECK(stream.value().closed());
        server.join();
        std::lock_guard lock(stream_state->mutex);
        CHECK_EQ(stream_state->outgoing.size(), 2U);
        CHECK_EQ(stream_state->close_calls, 1U);
    }
}

TEST("stream cancellation rejects malformed response envelopes once") {
    const auto run = [](std::string fields) {
        auto control = std::make_shared<FakeState>();
        auto stream_state = std::make_shared<FakeState>();
        auto client = client_for(control, stream_state);
        std::thread server([stream_state, fields = std::move(fields)] {
            wait_for_writes(stream_state, 1);
            cmux::Json open;
            {
                std::lock_guard lock(stream_state->mutex);
                open = cmux::Json::parse(
                           stream_state->outgoing.front())
                           .value();
            }
            const auto request_id =
                std::string(open.find("id")->as_string().value());
            const auto* params =
                open.find("params")->as_object().value();
            const auto stream_id = std::string(
                params->at("stream_id").as_string().value());
            enqueue(
                stream_state,
                stream_open_response(request_id, stream_id));

            wait_for_writes(stream_state, 2);
            cmux::Json cancel;
            {
                std::lock_guard lock(stream_state->mutex);
                cancel = cmux::Json::parse(
                             stream_state->outgoing.at(1))
                             .value();
            }
            const auto cancel_id =
                std::string(cancel.find("id")->as_string().value());
            enqueue(
                stream_state,
                "{\"protocol\":\"cmux.protocol/2\",\"type\":\"response\","
                "\"id\":\"" +
                    cancel_id + "\"," + fields + "}");
        });

        auto stream = client.open_session_events();
        CHECK(stream);
        auto first = stream.value().cancel();
        CHECK(!first);
        CHECK_EQ(first.error().code, cmux::ErrorCode::protocol);
        auto repeated = stream.value().cancel();
        CHECK(!repeated);
        CHECK_EQ(repeated.error().code, first.error().code);
        CHECK_EQ(repeated.error().message, first.error().message);
        CHECK(stream.value().closed());
        server.join();
        std::lock_guard lock(stream_state->mutex);
        CHECK_EQ(stream_state->outgoing.size(), 2U);
        CHECK_EQ(stream_state->close_calls, 1U);
    };

    run("\"ok\":true");
    run(
        "\"ok\":true,\"result\":{},\"error\":{\"code\":\"failed\","
        "\"message\":\"bad\",\"details\":{},\"retryable\":false}");
    run(
        "\"ok\":false,\"result\":{},\"error\":{\"code\":\"failed\","
        "\"message\":\"bad\",\"details\":{},\"retryable\":false}");
    run("\"ok\":true,\"result\":{},\"future\":true");
    run(
        "\"ok\":false,\"error\":{\"code\":\"failed\","
        "\"message\":\"bad\",\"details\":{},\"retryable\":false,"
        "\"future\":true}");
    run(
        "\"ok\":false,\"error\":{\"code\":\"failed\","
        "\"message\":\"bad\",\"retryable\":false}");
}

TEST("stream cancellation validates typed stale items before discard") {
    {
        auto control = std::make_shared<FakeState>();
        auto stream_state = std::make_shared<FakeState>();
        auto client = client_for(control, stream_state);
        std::thread server([stream_state] {
            wait_for_writes(stream_state, 1);
            cmux::Json open;
            {
                std::lock_guard lock(stream_state->mutex);
                open = cmux::Json::parse(
                           stream_state->outgoing.front())
                           .value();
            }
            const auto request_id =
                std::string(open.find("id")->as_string().value());
            const auto* params =
                open.find("params")->as_object().value();
            const auto stream_id = std::string(
                params->at("stream_id").as_string().value());
            enqueue(
                stream_state,
                stream_open_response(request_id, stream_id));

            wait_for_writes(stream_state, 2);
            cmux::Json cancel;
            {
                std::lock_guard lock(stream_state->mutex);
                cancel = cmux::Json::parse(
                             stream_state->outgoing.at(1))
                             .value();
            }
            const auto cancel_id =
                std::string(cancel.find("id")->as_string().value());
            enqueue(
                stream_state,
                "{\"protocol\":\"cmux.protocol/2\",\"type\":\"stream_item\","
                "\"stream_id\":\"" +
                    stream_id +
                    "\",\"sequence\":\"0\",\"cursor\":{\"generation\":\"g\","
                    "\"revision\":\"1\"},\"item\":{\"kind\":\"snapshot\","
                    "\"cursor\":{\"generation\":\"g\",\"revision\":\"1\"},"
                    "\"snapshot\":" +
                    resource_snapshot(1) + ",\"future\":true}}");
            enqueue(stream_state, response(cancel_id));
            enqueue(
                stream_state,
                "{\"protocol\":\"cmux.protocol/2\",\"type\":\"stream_end\","
                "\"stream_id\":\"" +
                    stream_id + "\",\"reason\":\"canceled\"}");
        });

        auto stream = client.open_session_events();
        CHECK(stream);
        auto first = stream.value().cancel();
        CHECK(!first);
        CHECK_EQ(first.error().code, cmux::ErrorCode::decode);
        CHECK(
            first.error().message.find("unknown field") !=
            std::string::npos);
        auto repeated = stream.value().cancel();
        CHECK(!repeated);
        CHECK_EQ(repeated.error().code, first.error().code);
        CHECK_EQ(repeated.error().message, first.error().message);
        CHECK(stream.value().closed());
        server.join();
        std::lock_guard lock(stream_state->mutex);
        CHECK_EQ(stream_state->outgoing.size(), 2U);
        CHECK_EQ(stream_state->close_calls, 1U);
    }

    {
        auto control = std::make_shared<FakeState>();
        auto stream_state = std::make_shared<FakeState>();
        auto client = client_for(control, stream_state);
        std::thread server([stream_state] {
            wait_for_writes(stream_state, 1);
            cmux::Json open;
            {
                std::lock_guard lock(stream_state->mutex);
                open = cmux::Json::parse(
                           stream_state->outgoing.front())
                           .value();
            }
            const auto request_id =
                std::string(open.find("id")->as_string().value());
            const auto* params =
                open.find("params")->as_object().value();
            const auto stream_id = std::string(
                params->at("stream_id").as_string().value());
            enqueue(
                stream_state,
                stream_open_response(request_id, stream_id));

            wait_for_writes(stream_state, 2);
            cmux::Json cancel;
            {
                std::lock_guard lock(stream_state->mutex);
                cancel = cmux::Json::parse(
                             stream_state->outgoing.at(1))
                             .value();
            }
            const auto cancel_id =
                std::string(cancel.find("id")->as_string().value());
            enqueue(
                stream_state,
                "{\"protocol\":\"cmux.protocol/2\",\"type\":\"stream_end\","
                "\"stream_id\":\"" +
                    stream_id + "\",\"reason\":\"canceled\"}");
            enqueue(
                stream_state,
                "{\"protocol\":\"cmux.protocol/2\",\"type\":\"stream_item\","
                "\"stream_id\":\"" +
                    stream_id +
                    "\",\"sequence\":\"0\",\"cursor\":{\"generation\":\"g\","
                    "\"revision\":\"1\"},\"item\":{\"kind\":\"snapshot\","
                    "\"cursor\":{\"generation\":\"g\",\"revision\":\"1\"},"
                    "\"snapshot\":" +
                    resource_snapshot(1) + ",\"future\":true}}");
            enqueue(stream_state, response(cancel_id));
        });

        auto stream = client.open_session_events();
        CHECK(stream);
        auto first = stream.value().cancel();
        CHECK(!first);
        CHECK_EQ(first.error().code, cmux::ErrorCode::protocol);
        CHECK(
            first.error().message.find("after stream end") !=
            std::string::npos);
        auto repeated = stream.value().cancel();
        CHECK(!repeated);
        CHECK_EQ(repeated.error().code, first.error().code);
        CHECK_EQ(repeated.error().message, first.error().message);
        CHECK(stream.value().closed());
        server.join();
        std::lock_guard lock(stream_state->mutex);
        CHECK_EQ(stream_state->outgoing.size(), 2U);
        CHECK_EQ(stream_state->close_calls, 1U);
    }

    {
        auto control = std::make_shared<FakeState>();
        auto stream_state = std::make_shared<FakeState>();
        auto client = client_for(control, stream_state);
        std::thread server([stream_state] {
            wait_for_writes(stream_state, 1);
            cmux::Json open;
            {
                std::lock_guard lock(stream_state->mutex);
                open = cmux::Json::parse(
                           stream_state->outgoing.front())
                           .value();
            }
            const auto request_id =
                std::string(open.find("id")->as_string().value());
            const auto* params =
                open.find("params")->as_object().value();
            const auto stream_id = std::string(
                params->at("stream_id").as_string().value());
            enqueue(
                stream_state,
                stream_open_response(request_id, stream_id));

            wait_for_writes(stream_state, 2);
            cmux::Json cancel;
            {
                std::lock_guard lock(stream_state->mutex);
                cancel = cmux::Json::parse(
                             stream_state->outgoing.at(1))
                             .value();
            }
            const auto cancel_id =
                std::string(cancel.find("id")->as_string().value());
            enqueue(
                stream_state,
                "{\"protocol\":\"cmux.protocol/2\",\"type\":\"stream_end\","
                "\"stream_id\":\"" +
                    stream_id + "\",\"reason\":\"canceled\"}");
            enqueue(
                stream_state,
                "{\"protocol\":\"cmux.protocol/2\",\"type\":\"stream_item\","
                "\"stream_id\":\"" +
                    stream_id +
                    "\",\"sequence\":\"0\",\"cursor\":{\"generation\":\"g\","
                    "\"revision\":\"1\"},\"item\":{\"kind\":\"snapshot\","
                    "\"cursor\":{\"generation\":\"g\",\"revision\":\"1\"},"
                    "\"reset_reason\":\"initial\",\"snapshot\":" +
                    resource_snapshot(1) + "}}");
            enqueue(stream_state, response(cancel_id));
        });

        auto stream = client.open_session_events();
        CHECK(stream);
        auto first = stream.value().cancel();
        CHECK(!first);
        CHECK_EQ(
            first.error().code,
            cmux::ErrorCode::protocol);
        CHECK(
            first.error().message.find("after stream end") !=
            std::string::npos);
        auto repeated = stream.value().cancel();
        CHECK(!repeated);
        CHECK_EQ(repeated.error().code, first.error().code);
        CHECK_EQ(repeated.error().message, first.error().message);
        CHECK(stream.value().closed());
        server.join();
        std::lock_guard lock(stream_state->mutex);
        CHECK_EQ(stream_state->outgoing.size(), 2U);
        CHECK_EQ(stream_state->close_calls, 1U);
    }
}

TEST("stream cancellation has one total deadline across stale item drip") {
    auto control = std::make_shared<FakeState>();
    auto stream_state = std::make_shared<FakeState>();
    constexpr auto cancel_timeout = std::chrono::milliseconds(80);
    constexpr auto drip_delay = std::chrono::milliseconds(25);
    auto client = client_for(control, stream_state, cancel_timeout);

    std::thread server([stream_state] {
        wait_for_writes(stream_state, 1);
        cmux::Json open;
        {
            std::lock_guard lock(stream_state->mutex);
            open = cmux::Json::parse(
                       stream_state->outgoing.front())
                       .value();
        }
        const auto request_id =
            std::string(open.find("id")->as_string().value());
        const auto* params = open.find("params")->as_object().value();
        const auto stream_id = std::string(
            params->at("stream_id").as_string().value());
        enqueue(
            stream_state,
            stream_open_response(request_id, stream_id));
    });

    auto stream = client.open_session_events();
    CHECK(stream);
    server.join();
    std::string stream_id;
    {
        std::lock_guard lock(stream_state->mutex);
        const auto open =
            cmux::Json::parse(stream_state->outgoing.front()).value();
        const auto* params = open.find("params")->as_object().value();
        stream_id =
            std::string(params->at("stream_id").as_string().value());
        stream_state->receive_delay = drip_delay;
    }
    for (std::uint64_t sequence = 1; sequence <= 20; ++sequence) {
        enqueue(
            stream_state,
            "{\"protocol\":\"cmux.protocol/2\",\"type\":\"stream_item\","
            "\"stream_id\":\"" +
                stream_id + "\",\"sequence\":\"" +
                std::to_string(sequence) +
                "\",\"cursor\":{\"generation\":\"g\",\"revision\":\"" +
                std::to_string(sequence) +
                "\"},\"item\":{\"kind\":\"stale\"}}");
    }

    const auto started = std::chrono::steady_clock::now();
    auto canceled = stream.value().cancel();
    const auto elapsed =
        std::chrono::steady_clock::now() - started;
    CHECK(!canceled);
    CHECK_EQ(canceled.error().code, cmux::ErrorCode::timeout);
    CHECK(
        elapsed < std::chrono::milliseconds(300));
    auto repeated = stream.value().cancel();
    CHECK(!repeated);
    CHECK_EQ(repeated.error().code, cmux::ErrorCode::timeout);
    CHECK_EQ(repeated.error().message, canceled.error().message);
    CHECK(stream.value().closed());
    std::lock_guard lock(stream_state->mutex);
    CHECK_EQ(stream_state->outgoing.size(), 2U);
    CHECK_EQ(stream_state->close_calls, 1U);
    CHECK(!stream_state->incoming.empty());
}

TEST("stream cancellation rejects wrong or malformed terminal ends once") {
    const auto run = [](
                         std::string fields,
                         cmux::ErrorCode expected,
                         bool wrong_stream_id = false) {
        auto control = std::make_shared<FakeState>();
        auto stream_state = std::make_shared<FakeState>();
        auto client = client_for(control, stream_state);
        std::thread server([
            stream_state,
            fields = std::move(fields),
            wrong_stream_id
        ] {
            wait_for_writes(stream_state, 1);
            cmux::Json open;
            {
                std::lock_guard lock(stream_state->mutex);
                open = cmux::Json::parse(
                           stream_state->outgoing.front())
                           .value();
            }
            const auto request_id =
                std::string(open.find("id")->as_string().value());
            const auto* params =
                open.find("params")->as_object().value();
            const auto stream_id = std::string(
                params->at("stream_id").as_string().value());
            enqueue(
                stream_state,
                stream_open_response(request_id, stream_id));

            wait_for_writes(stream_state, 2);
            cmux::Json cancel;
            {
                std::lock_guard lock(stream_state->mutex);
                cancel = cmux::Json::parse(
                             stream_state->outgoing.at(1))
                             .value();
            }
            const auto cancel_id =
                std::string(cancel.find("id")->as_string().value());
            enqueue(stream_state, response(cancel_id));
            enqueue(
                stream_state,
                "{\"protocol\":\"cmux.protocol/2\",\"type\":\"stream_end\","
                "\"stream_id\":\"" +
                    (wrong_stream_id
                         ? "stream_ffffffffffffffffffffffffffffffff"
                         : stream_id) +
                    "\"," + fields + "}");
        });

        auto stream = client.open_session_events();
        CHECK(stream);
        auto first = stream.value().cancel();
        CHECK(!first);
        CHECK_EQ(first.error().code, expected);
        auto repeated = stream.value().cancel();
        CHECK(!repeated);
        CHECK_EQ(repeated.error().code, first.error().code);
        CHECK_EQ(repeated.error().message, first.error().message);
        CHECK(stream.value().closed());
        server.join();
        std::lock_guard lock(stream_state->mutex);
        CHECK_EQ(stream_state->outgoing.size(), 2U);
        CHECK_EQ(stream_state->close_calls, 1U);
    };

    run("\"reason\":\"completed\"", cmux::ErrorCode::protocol);
    run(
        "\"reason\":\"canceled\"",
        cmux::ErrorCode::protocol,
        true);
    run(
        "\"reason\":\"canceled\",\"future\":true",
        cmux::ErrorCode::decode);
    run(
        "\"reason\":\"canceled\",\"cursor\":null",
        cmux::ErrorCode::decode);
    run(
        "\"reason\":\"canceled\",\"cursor\":{\"generation\":\"g\","
        "\"revision\":1}",
        cmux::ErrorCode::decode);
    run(
        "\"reason\":\"canceled\",\"recovery\":null",
        cmux::ErrorCode::decode);
    run(
        "\"reason\":\"canceled\",\"error\":{\"code\":\"failed\","
        "\"message\":\"bad\",\"details\":{},\"retryable\":\"no\"}",
        cmux::ErrorCode::decode);
    run(
        "\"reason\":\"canceled\",\"error\":{\"code\":\"failed\","
        "\"message\":\"bad\",\"details\":{},\"retryable\":false}",
        cmux::ErrorCode::decode);
    run("\"reason\":\"error\"", cmux::ErrorCode::decode);
}

TEST("stream items require exact canonical envelopes") {
    const auto run = [](
                         std::string fields,
                         cmux::ErrorCode expected,
                         std::string type = "stream_item",
                         bool wrong_stream_id = false) {
        auto control = std::make_shared<FakeState>();
        auto stream_state = std::make_shared<FakeState>();
        auto client = client_for(control, stream_state);
        std::thread server([
            stream_state,
            fields = std::move(fields),
            type = std::move(type),
            wrong_stream_id
        ] {
            wait_for_writes(stream_state, 1);
            cmux::Json open;
            {
                std::lock_guard lock(stream_state->mutex);
                open = cmux::Json::parse(
                           stream_state->outgoing.front())
                           .value();
            }
            const auto request_id =
                std::string(open.find("id")->as_string().value());
            const auto* params =
                open.find("params")->as_object().value();
            const auto stream_id = std::string(
                params->at("stream_id").as_string().value());
            enqueue(
                stream_state,
                stream_open_response(request_id, stream_id));
            enqueue(
                stream_state,
                "{\"protocol\":\"cmux.protocol/2\",\"type\":\"" + type +
                    "\",\"stream_id\":\"" +
                    (wrong_stream_id
                         ? "stream_ffffffffffffffffffffffffffffffff"
                         : stream_id) +
                    "\"," + fields + "}");
        });

        auto stream = client.open_session_events();
        CHECK(stream);
        auto first = stream.value().next();
        CHECK(!first);
        CHECK_EQ(first.error().code, expected);
        auto repeated = stream.value().next();
        CHECK(!repeated);
        CHECK_EQ(repeated.error().code, cmux::ErrorCode::closed);
        CHECK(stream.value().closed());
        server.join();
        std::lock_guard lock(stream_state->mutex);
        CHECK_EQ(stream_state->outgoing.size(), 1U);
        CHECK_EQ(stream_state->close_calls, 1U);
    };

    run(
        "\"sequence\":\"0\",\"item\":{\"kind\":\"future\"},"
        "\"future\":true",
        cmux::ErrorCode::decode);
    run(
        "\"sequence\":\"0\",\"cursor\":null,"
        "\"item\":{\"kind\":\"future\"}",
        cmux::ErrorCode::decode);
    run(
        "\"sequence\":0,\"item\":{\"kind\":\"future\"}",
        cmux::ErrorCode::decode);
    run(
        "\"sequence\":\"00\",\"item\":{\"kind\":\"future\"}",
        cmux::ErrorCode::decode);
    run("\"sequence\":\"0\"", cmux::ErrorCode::decode);
    run(
        "\"sequence\":\"0\",\"item\":{\"kind\":\"future\"}",
        cmux::ErrorCode::protocol,
        "future_item");
    run(
        "\"sequence\":\"0\",\"item\":{\"kind\":\"future\"}",
        cmux::ErrorCode::protocol,
        "stream_item",
        true);
}

TEST("attachment resize and release stay on the dedicated stream connection") {
    auto control = std::make_shared<FakeState>();
    auto stream_state = std::make_shared<FakeState>();
    auto client = client_for(control, stream_state);
    std::atomic<bool> open_route_ok{false};
    std::atomic<bool> resize_route_ok{false};
    std::atomic<bool> release_route_ok{false};

    std::thread server([
        stream_state,
        &open_route_ok,
        &resize_route_ok,
        &release_route_ok
    ] {
        wait_for_writes(stream_state, 1);
        cmux::Json open;
        {
            std::lock_guard lock(stream_state->mutex);
            open = cmux::Json::parse(stream_state->outgoing.at(0)).value();
        }
        const auto request_id =
            std::string(open.find("id")->as_string().value());
        const auto* open_params = open.find("params")->as_object().value();
        const auto stream_id =
            std::string(open_params->at("stream_id").as_string().value());
        open_route_ok.store(
            open.find("operation")->as_string().value() ==
                    "terminal.attach" &&
                open_params->at("terminal").as_string().value() ==
                    "term_0123456789abcdef0123456789abcdef" &&
                open_params->at("cols").as_uint64().value() == 80U &&
                open_params->at("rows").as_uint64().value() == 24U &&
                open_params->at("read_only").as_bool().value(),
            std::memory_order_release);
        enqueue(
            stream_state,
            attachment_open_response(
                request_id,
                stream_id,
                "terminal-lease"));

        wait_for_writes(stream_state, 2);
        cmux::Json resize;
        {
            std::lock_guard lock(stream_state->mutex);
            resize = cmux::Json::parse(stream_state->outgoing.at(1)).value();
        }
        const auto resize_id =
            std::string(resize.find("id")->as_string().value());
        const auto* resize_params =
            resize.find("params")->as_object().value();
        resize_route_ok.store(
            resize.find("operation")->as_string().value() ==
                    "terminal.viewer.resize" &&
                resize_params->at("terminal").as_string().value() ==
                    "term_0123456789abcdef0123456789abcdef" &&
                resize_params->at("attachment_lease").as_string().value() ==
                    "terminal-lease" &&
                resize_params->at("cols").as_uint64().value() == 100U &&
                resize_params->at("rows").as_uint64().value() == 40U,
            std::memory_order_release);
        enqueue(
            stream_state,
            response(
                resize_id,
                R"({"accepted":true,"size":{"cols":100,"rows":40},"outcome":"applied"})"));

        wait_for_writes(stream_state, 3);
        cmux::Json release;
        {
            std::lock_guard lock(stream_state->mutex);
            release =
                cmux::Json::parse(stream_state->outgoing.at(2)).value();
        }
        const auto release_id =
            std::string(release.find("id")->as_string().value());
        const auto* release_params =
            release.find("params")->as_object().value();
        release_route_ok.store(
            release.find("operation")->as_string().value() ==
                    "terminal.viewer.release" &&
                release_params->at("terminal").as_string().value() ==
                    "term_0123456789abcdef0123456789abcdef" &&
                release_params->at("attachment_lease").as_string().value() ==
                    "terminal-lease",
            std::memory_order_release);
        enqueue(
            stream_state,
            response(release_id, R"({"outcome":"applied"})"));
    });

    auto terminal_id = cmux::TerminalId::parse(
        "term_0123456789abcdef0123456789abcdef");
    CHECK(terminal_id);
    cmux::TerminalAttachOptions attach;
    attach.cols = 80;
    attach.rows = 24;
    attach.read_only = true;
    auto stream = client.terminal(std::move(terminal_id).value())
                      .attach(attach);
    CHECK(stream);
    auto resized = stream.value().resize_viewer(100, 40);
    CHECK(resized);
    CHECK(resized.value().accepted);
    CHECK_EQ(resized.value().size.cols, 100U);
    CHECK_EQ(
        resized.value().outcome,
        cmux::ViewerResizeResult::Outcome::applied);
    auto released = stream.value().release_viewer();
    CHECK(released);
    CHECK_EQ(
        released.value().outcome,
        cmux::ViewerResizeResult::Outcome::applied);
    server.join();
    CHECK(open_route_ok.load(std::memory_order_acquire));
    CHECK(resize_route_ok.load(std::memory_order_acquire));
    CHECK(release_route_ok.load(std::memory_order_acquire));
    std::lock_guard lock(control->mutex);
    CHECK(control->outgoing.empty());
}

TEST("connection-control send failure closes the dedicated stream") {
    auto control = std::make_shared<FakeState>();
    auto stream_state = std::make_shared<FakeState>();
    stream_state->fail_send_call = 2U;
    stream_state->record_failed_send = true;
    auto client = client_for(control, stream_state);

    std::thread server([stream_state] {
        wait_for_writes(stream_state, 1);
        cmux::Json open;
        {
            std::lock_guard lock(stream_state->mutex);
            open = cmux::Json::parse(
                       stream_state->outgoing.front())
                       .value();
        }
        const auto request_id =
            std::string(open.find("id")->as_string().value());
        const auto* params = open.find("params")->as_object().value();
        const auto stream_id = std::string(
            params->at("stream_id").as_string().value());
        enqueue(
            stream_state,
            stream_open_response(request_id, stream_id));
    });

    auto stream = client.open_session_events();
    CHECK(stream);
    server.join();
    auto controlled = stream.value().connection_control(
        cmux::Operation::client_cell_pixels_set,
        {
            {"width_px", cmux::Json(std::uint64_t{8})},
            {"height_px", cmux::Json(std::uint64_t{16})},
        });
    CHECK(!controlled);
    CHECK_EQ(controlled.error().code, cmux::ErrorCode::connection);
    CHECK_EQ(
        controlled.error().message,
        std::string("synthetic framing-uncertain send failure"));
    CHECK(stream.value().closed());
    auto canceled = stream.value().cancel();
    CHECK(!canceled);
    CHECK_EQ(canceled.error().code, cmux::ErrorCode::closed);
    std::lock_guard lock(stream_state->mutex);
    CHECK_EQ(stream_state->outgoing.size(), 2U);
    CHECK_EQ(stream_state->close_calls, 1U);
}

TEST("connection-control overflow closes the stream without a second cleanup") {
    auto control = std::make_shared<FakeState>();
    auto stream_state = std::make_shared<FakeState>();
    auto client = client_for(control, stream_state);

    std::thread server([stream_state] {
        wait_for_writes(stream_state, 1);
        cmux::Json open;
        {
            std::lock_guard lock(stream_state->mutex);
            open = cmux::Json::parse(
                       stream_state->outgoing.front())
                       .value();
        }
        const auto request_id =
            std::string(open.find("id")->as_string().value());
        const auto* params = open.find("params")->as_object().value();
        const auto stream_id = std::string(
            params->at("stream_id").as_string().value());
        enqueue(
            stream_state,
            stream_open_response(request_id, stream_id));

        wait_for_writes(stream_state, 2);
        for (std::uint64_t sequence = 1; sequence <= 257; ++sequence) {
            enqueue(
                stream_state,
                "{\"protocol\":\"cmux.protocol/2\",\"type\":\"stream_item\","
                "\"stream_id\":\"" +
                    stream_id + "\",\"sequence\":\"" +
                    std::to_string(sequence) +
                    "\",\"item\":{\"kind\":\"future\"}}");
        }
    });

    auto stream = client.open_session_events();
    CHECK(stream);
    auto controlled = stream.value().connection_control(
        cmux::Operation::client_cell_pixels_set,
        {
            {"width_px", cmux::Json(std::uint64_t{8})},
            {"height_px", cmux::Json(std::uint64_t{16})},
        });
    CHECK(!controlled);
    CHECK_EQ(
        controlled.error().code,
        cmux::ErrorCode::stream_local_overflow);
    CHECK(stream.value().closed());
    auto canceled = stream.value().cancel();
    CHECK(!canceled);
    CHECK_EQ(canceled.error().code, cmux::ErrorCode::closed);
    server.join();
    std::lock_guard lock(stream_state->mutex);
    CHECK_EQ(stream_state->outgoing.size(), 2U);
    CHECK_EQ(stream_state->close_calls, 1U);
}

TEST("stream open rejects a locally overflowing pre-ack queue") {
    auto control = std::make_shared<FakeState>();
    auto stream_state = std::make_shared<FakeState>();
    auto client = client_for(control, stream_state);

    std::thread server([stream_state] {
        wait_for_writes(stream_state, 1);
        cmux::Json open;
        {
            std::lock_guard lock(stream_state->mutex);
            open = cmux::Json::parse(stream_state->outgoing.at(0)).value();
        }
        const auto request_id =
            std::string(open.find("id")->as_string().value());
        const auto* params = open.find("params")->as_object().value();
        const auto stream_id =
            std::string(params->at("stream_id").as_string().value());
        for (std::uint64_t sequence = 1; sequence <= 257; ++sequence) {
            enqueue(
                stream_state,
                "{\"protocol\":\"cmux.protocol/2\",\"type\":\"stream_item\","
                "\"stream_id\":\"" +
                    stream_id + "\",\"sequence\":\"" +
                    std::to_string(sequence) +
                    "\",\"item\":{\"kind\":\"future\"}}");
        }
        enqueue(
            stream_state,
            stream_open_response(request_id, stream_id));
    });

    auto stream = client.open_terminal_attachment({
        {
            "terminal",
            cmux::Json(
                "term_0123456789abcdef0123456789abcdef"),
        },
    });
    CHECK(!stream);
    CHECK_EQ(
        stream.error().code,
        cmux::ErrorCode::stream_local_overflow);
    server.join();
    std::lock_guard lock(stream_state->mutex);
    CHECK(stream_state->closed);
    CHECK_EQ(stream_state->close_calls, 1U);
    CHECK_EQ(stream_state->outgoing.size(), 1U);
}

TEST("stream open enforces the local buffered byte limit") {
    auto control = std::make_shared<FakeState>();
    auto stream_state = std::make_shared<FakeState>();
    auto client = client_for(control, stream_state);

    std::thread server([stream_state] {
        wait_for_writes(stream_state, 1);
        cmux::Json open;
        {
            std::lock_guard lock(stream_state->mutex);
            open = cmux::Json::parse(stream_state->outgoing.at(0)).value();
        }
        const auto* params = open.find("params")->as_object().value();
        const auto stream_id =
            std::string(params->at("stream_id").as_string().value());
        const std::string payload(6U * 1024U * 1024U, 'x');
        for (std::uint64_t sequence = 1; sequence <= 3; ++sequence) {
            enqueue(
                stream_state,
                "{\"protocol\":\"cmux.protocol/2\",\"type\":\"stream_item\","
                "\"stream_id\":\"" + stream_id + "\",\"sequence\":\"" +
                    std::to_string(sequence) +
                    "\",\"item\":{\"kind\":\"future\",\"payload\":\"" +
                    payload + "\"}}");
        }
    });

    auto stream = client.open_terminal_attachment({
        {
            "terminal",
            cmux::Json("term_0123456789abcdef0123456789abcdef"),
        },
    });
    CHECK(!stream);
    CHECK_EQ(
        stream.error().code,
        cmux::ErrorCode::stream_local_overflow);
    server.join();
    std::lock_guard lock(stream_state->mutex);
    CHECK(stream_state->closed);
    CHECK_EQ(stream_state->close_calls, 1U);
    CHECK_EQ(stream_state->outgoing.size(), 1U);
}

TEST("session stream events discriminate snapshot and delta at compile time") {
    auto control = std::make_shared<FakeState>();
    auto stream_state = std::make_shared<FakeState>();
    auto client = client_for(control, stream_state);

    std::thread server([stream_state] {
        wait_for_writes(stream_state, 1);
        cmux::Json open;
        {
            std::lock_guard lock(stream_state->mutex);
            open =
                cmux::Json::parse(stream_state->outgoing.at(0)).value();
        }
        const auto request_id =
            std::string(open.find("id")->as_string().value());
        const auto* params = open.find("params")->as_object().value();
        const auto stream_id =
            std::string(params->at("stream_id").as_string().value());
        enqueue(
            stream_state,
            "{\"protocol\":\"cmux.protocol/2\",\"type\":\"stream_item\","
            "\"stream_id\":\"" +
                stream_id +
                "\",\"sequence\":\"1\",\"cursor\":{\"generation\":\"g\","
                "\"revision\":\"1\"},\"item\":{\"kind\":\"snapshot\","
                "\"cursor\":{\"generation\":\"g\",\"revision\":\"1\"},"
                "\"reset_reason\":\"initial\",\"snapshot\":" +
                resource_snapshot(1) + "}}");
        enqueue(
            stream_state,
            "{\"protocol\":\"cmux.protocol/2\",\"type\":\"stream_item\","
            "\"stream_id\":\"" +
                stream_id +
                "\",\"sequence\":\"2\",\"cursor\":{\"generation\":\"g\","
                "\"revision\":\"2\"},\"item\":{\"kind\":\"delta\","
                "\"cursor\":{\"generation\":\"g\",\"revision\":\"2\"},"
                "\"previous_revision\":\"1\",\"revision\":\"2\","
                "\"changes\":[]}}");
        enqueue(
            stream_state,
            "{\"protocol\":\"cmux.protocol/2\",\"type\":\"stream_end\","
            "\"stream_id\":\"" +
                stream_id + "\",\"reason\":\"completed\"}");
        enqueue(
            stream_state,
            stream_open_response(request_id, stream_id));
    });

    auto stream = client.open_session_events();
    CHECK(stream);
    auto snapshot_item = stream.value().next();
    CHECK(snapshot_item);
    CHECK(snapshot_item.value().has_value());
    const auto* snapshot =
        std::get_if<cmux::SessionSnapshotEvent>(
            &snapshot_item.value()->value);
    CHECK(snapshot != nullptr);
    CHECK_EQ(snapshot->cursor.revision, 1U);
    CHECK(snapshot->reset_reason.has_value());
    CHECK_EQ(
        *snapshot->reset_reason,
        cmux::SessionResetReason::initial);
    CHECK(snapshot->snapshot.workspaces.empty());

    auto delta_item = stream.value().next();
    CHECK(delta_item);
    CHECK(delta_item.value().has_value());
    const auto* delta =
        std::get_if<cmux::SessionDeltaEvent>(&delta_item.value()->value);
    CHECK(delta != nullptr);
    CHECK_EQ(delta->previous_revision, 1U);
    CHECK_EQ(delta->revision, 2U);
    CHECK(delta->changes.empty());

    auto end = stream.value().next();
    CHECK(end);
    CHECK(!end.value().has_value());
    CHECK(stream.value().end().has_value());
    CHECK_EQ(
        stream.value().end()->reason,
        cmux::StreamEndReason::completed);
    server.join();
}

TEST("malformed known session events never downgrade to Unknown") {
    auto control = std::make_shared<FakeState>();
    auto stream_state = std::make_shared<FakeState>();
    auto client = client_for(control, stream_state);

    std::thread server([stream_state] {
        wait_for_writes(stream_state, 1);
        cmux::Json open;
        {
            std::lock_guard lock(stream_state->mutex);
            open =
                cmux::Json::parse(stream_state->outgoing.at(0)).value();
        }
        const auto request_id =
            std::string(open.find("id")->as_string().value());
        const auto* params = open.find("params")->as_object().value();
        const auto stream_id =
            std::string(params->at("stream_id").as_string().value());
        enqueue(
            stream_state,
            "{\"protocol\":\"cmux.protocol/2\",\"type\":\"stream_item\","
            "\"stream_id\":\"" +
                stream_id +
                "\",\"sequence\":\"1\",\"cursor\":{\"generation\":\"g\","
                "\"revision\":\"1\"},\"item\":{\"kind\":\"snapshot\","
                "\"cursor\":{\"generation\":\"g\",\"revision\":\"1\"},"
                "\"future\":true}}");
        enqueue(
            stream_state,
            stream_open_response(request_id, stream_id));
    });

    auto stream = client.open_session_events();
    CHECK(stream);
    auto item = stream.value().next();
    CHECK(!item);
    CHECK_EQ(item.error().code, cmux::ErrorCode::decode);
    CHECK(
        item.error().message.find("unknown field") != std::string::npos);
    server.join();
}
