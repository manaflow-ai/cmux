#include "test.hpp"

#include <chrono>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <sstream>
#include <stop_token>
#include <string>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>

#include "cmux/client.hpp"
#include "cmux/raw/client.hpp"

namespace {

struct FakeState {
    std::mutex mutex;
    std::condition_variable changed;
    std::deque<std::string> incoming;
    std::vector<std::string> outgoing;
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
        state_->outgoing.emplace_back(message);
        state_->changed.notify_all();
        return {};
    }

    cmux::Result<std::string> receive(cmux::Timeout timeout) override {
        std::unique_lock lock(state_->mutex);
        if (!state_->changed.wait_for(lock, timeout, [this] {
                return state_->closed || !state_->incoming.empty();
            })) {
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

cmux::Client client_for(
    const std::shared_ptr<FakeState>& control,
    const std::shared_ptr<FakeState>& stream = {}) {
    cmux::ClientOptions options;
    options.timeout = std::chrono::seconds(2);
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
    return "{\"protocol\":\"cmux.protocol/1\",\"type\":\"response\",\"id\":\"" +
           id + "\",\"ok\":true,\"result\":" + result + "}";
}

std::string stream_open_response(
    const std::string& request_id,
    const std::string& stream_id) {
    return response(
        request_id,
        "{\"stream_id\":\"" + stream_id + "\"}");
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
    return "{\"protocol\":\"cmux.protocol/1\",\"type\":\"response\",\"id\":\"" +
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
    check(split.to_params());

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
        cmux::operation_name(cmux::Operation::tab_create_browser),
        std::string_view("tab.create_browser"));
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
        R"({"protocol":"cmux.protocol/1","type":"response","id":"cpp-request-1","ok":false,"error":{"code":"selector.ambiguous","message":"two matches","details":{"token":"must-not-log","candidates":["ws_0123456789abcdef0123456789abcdef"]},"retryable":false}})");
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

TEST("layout undo requires and carries typed confirmation details") {
    cmux::UndoLayoutOptions missing_token{
        .confirm_close = true,
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
        R"({"protocol":"cmux.protocol/1","type":"response","id":"cpp-request-1","ok":false,"error":{"code":"mutation.indeterminate","message":"external effect may have committed","details":{"idempotency_key":"indeterminate-test-key","operation":"workspace.rename","recovery":"inspect_state_then_retry_with_new_key"},"retryable":false}})");
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

TEST("terminal lifecycle and wait-exit unions decode strictly") {
    auto running = cmux::detail::decode_value<cmux::TerminalSnapshot>(
        cmux::Json::parse(
            R"({"id":"term_0123456789abcdef0123456789abcdef","tab_id":"tab_0123456789abcdef0123456789abcdef","title":"shell","cols":80,"rows":24,"running":true,"lifecycle":"running"})")
            .value());
    CHECK(running);
    CHECK_EQ(
        running.value().lifecycle,
        cmux::TerminalLifecycle::running);
    CHECK(!running.value().exit.has_value());

    auto exited = cmux::detail::decode_value<cmux::TerminalSnapshot>(
        cmux::Json::parse(
            R"({"id":"term_0123456789abcdef0123456789abcdef","tab_id":"tab_0123456789abcdef0123456789abcdef","title":"done","cols":80,"rows":24,"running":false,"lifecycle":"exited","exit":{"outcome":{"kind":"exit","code":0},"exited_at":"123","revision":"9"}})")
            .value());
    CHECK(exited);
    CHECK(exited.value().exit.has_value());
    CHECK(std::holds_alternative<cmux::TerminalExitCode>(
        exited.value().exit->outcome));

    auto inconsistent =
        cmux::detail::decode_value<cmux::TerminalSnapshot>(
            cmux::Json::parse(
                R"({"id":"term_0123456789abcdef0123456789abcdef","tab_id":"tab_0123456789abcdef0123456789abcdef","title":"bad","cols":80,"rows":24,"running":true,"lifecycle":"launching"})")
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
            "{\"protocol\":\"cmux.protocol/1\",\"type\":\"stream_item\","
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
            "{\"protocol\":\"cmux.protocol/1\",\"type\":\"stream_end\","
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

TEST("attachment resize and release stay on the dedicated stream connection") {
    auto control = std::make_shared<FakeState>();
    auto stream_state = std::make_shared<FakeState>();
    auto client = client_for(control, stream_state);
    std::atomic<bool> route_ok{false};

    std::thread server([stream_state, &route_ok] {
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
        enqueue(
            stream_state,
            stream_open_response(request_id, stream_id));

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
        route_ok.store(
            resize.find("operation")->as_string().value() ==
                    "terminal.viewer.resize" &&
                resize_params->at("terminal").as_string().value() ==
                    "term_0123456789abcdef0123456789abcdef" &&
                resize_params->at("cols").as_uint64().value() == 100U &&
                resize_params->at("rows").as_uint64().value() == 40U,
            std::memory_order_release);
        enqueue(
            stream_state,
            response(
                resize_id,
                R"({"accepted":true,"size":{"cols":100,"rows":40}})"));

        wait_for_writes(stream_state, 3);
        cmux::Json release;
        {
            std::lock_guard lock(stream_state->mutex);
            release =
                cmux::Json::parse(stream_state->outgoing.at(2)).value();
        }
        const auto release_id =
            std::string(release.find("id")->as_string().value());
        enqueue(stream_state, response(release_id));
    });

    auto stream = client.open_terminal_attachment({
        {
            "terminal",
            cmux::Json(
                "term_0123456789abcdef0123456789abcdef"),
        },
    });
    CHECK(stream);
    auto resized = stream.value().resize_viewer(100, 40);
    CHECK(resized);
    CHECK(resized.value().accepted);
    CHECK_EQ(resized.value().size.cols, 100U);
    auto released = stream.value().release_viewer();
    CHECK(released);
    server.join();
    CHECK(route_ok.load(std::memory_order_acquire));
    std::lock_guard lock(control->mutex);
    CHECK(control->outgoing.empty());
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
                "{\"protocol\":\"cmux.protocol/1\",\"type\":\"stream_item\","
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
            "{\"protocol\":\"cmux.protocol/1\",\"type\":\"stream_item\","
            "\"stream_id\":\"" +
                stream_id +
                "\",\"sequence\":\"1\",\"cursor\":{\"generation\":\"g\","
                "\"revision\":\"1\"},\"item\":{\"kind\":\"snapshot\","
                "\"cursor\":{\"generation\":\"g\",\"revision\":\"1\"},"
                "\"reset_reason\":\"initial\",\"snapshot\":" +
                resource_snapshot(1) + "}}");
        enqueue(
            stream_state,
            "{\"protocol\":\"cmux.protocol/1\",\"type\":\"stream_item\","
            "\"stream_id\":\"" +
                stream_id +
                "\",\"sequence\":\"2\",\"cursor\":{\"generation\":\"g\","
                "\"revision\":\"2\"},\"item\":{\"kind\":\"delta\","
                "\"cursor\":{\"generation\":\"g\",\"revision\":\"2\"},"
                "\"previous_revision\":\"1\",\"revision\":\"2\","
                "\"changes\":[]}}");
        enqueue(
            stream_state,
            "{\"protocol\":\"cmux.protocol/1\",\"type\":\"stream_end\","
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
            "{\"protocol\":\"cmux.protocol/1\",\"type\":\"stream_item\","
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
