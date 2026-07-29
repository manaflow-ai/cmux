#include "test.hpp"

#include <chrono>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <sstream>
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

}  // namespace

static_assert(!std::is_copy_constructible_v<cmux::ResourceStream>);
static_assert(std::is_nothrow_move_constructible_v<cmux::ResourceStream>);
static_assert(!std::is_copy_constructible_v<cmux::TerminalAttachmentStream>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::raw::Client&>().identify()),
              cmux::Result<cmux::raw::IdentifyResult>>);
template <typename T>
concept HasMutationReceipt = requires(T value) {
    value.receipt;
};
static_assert(!HasMutationReceipt<cmux::MutationResult>);

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
    CHECK_EQ(
        cmux::operation_class(cmux::Operation::provider_notice_events),
        cmux::OperationClass::stream_open);
    CHECK_EQ(
        cmux::operation_class(
            cmux::Operation::provider_notice_acknowledge),
        cmux::OperationClass::connection_control);
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
    auto created_path = result.value().created_path();
    CHECK(created_path);
    CHECK(!created_path.value().has_value());

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
        result.error().protocol_code,
        std::string("mutation.indeterminate"));
    CHECK_EQ(
        result.error().message,
        std::string("external effect may have committed"));
    CHECK(!result.error().retryable);
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

TEST("client metadata preserves omitted set-empty and clear states") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    enqueue(state, response("cpp-request-1", R"({"name":""})"));
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

TEST("provider notices acknowledge only after an explicit consumer call") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    enqueue(state, response("cpp-request-1"));
    auto scope = cmux::ProviderScopeId::parse(
        "provider_scope_0123456789abcdef0123456789abcdef");
    auto notice = cmux::ProviderNoticeId::parse(
        "provider_notice_0123456789abcdef0123456789abcdef");
    CHECK(scope);
    CHECK(notice);
    auto result = client.provider_scope(std::move(scope).value())
                      .notice(std::move(notice).value())
                      .acknowledge(42);
    CHECK(result);

    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 1U);
    auto envelope = cmux::Json::parse(state->outgoing.front());
    CHECK(envelope);
    CHECK_EQ(
        envelope.value().find("operation")->as_string().value(),
        std::string_view("provider_notice.acknowledge"));
    CHECK(envelope.value().find("idempotency_key") == nullptr);
    const auto* params =
        envelope.value().find("params")->as_object().value();
    CHECK_EQ(
        params->at("machine").as_string().value(),
        std::string_view("current"));
    CHECK(!params->contains("session"));
    CHECK_EQ(
        params->at("provider_scope").as_string().value(),
        std::string_view(
            "provider_scope_0123456789abcdef0123456789abcdef"));
    CHECK_EQ(
        params->at("provider_notice").as_string().value(),
        std::string_view(
            "provider_notice_0123456789abcdef0123456789abcdef"));
    CHECK_EQ(
        params->at("sequence").as_string().value(),
        std::string_view("42"));
}

TEST("renderer grants and provider secrets never format capabilities") {
    cmux::ProviderCredential credential("provider-secret");
    std::ostringstream provider_output;
    provider_output << credential;
    CHECK_EQ(provider_output.str(), std::string("[REDACTED]"));

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

TEST("copying and dropping a handle performs no IO") {
    auto state = std::make_shared<FakeState>();
    auto client = client_for(state);
    auto id = cmux::WorkspaceId::parse(
        "ws_0123456789abcdef0123456789abcdef");
    CHECK(id);
    {
        auto workspace = client.workspace(std::move(id).value());
        auto copied = workspace;
        CHECK_EQ(copied.id().value(), workspace.id().value());
    }
    std::lock_guard lock(state->mutex);
    CHECK(state->outgoing.empty());
}

TEST("typed streams preserve unknown items and cancel deterministically") {
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
                "\"revision\":\"9\"},\"item\":{\"event\":\"future.event\","
                "\"data\":{\"x\":1},\"future\":true}}");
        enqueue(stream_state, response(request_id));

        wait_for_writes(stream_state, 2);
        cmux::Json cancel;
        {
            std::lock_guard lock(stream_state->mutex);
            cancel =
                cmux::Json::parse(stream_state->outgoing.at(1)).value();
        }
        const auto cancel_id =
            std::string(cancel.find("id")->as_string().value());
        enqueue(
            stream_state,
            "{\"protocol\":\"cmux.protocol/1\",\"type\":\"stream_end\","
            "\"stream_id\":\"" +
                stream_id +
                "\",\"reason\":\"canceled\",\"cursor\":{\"generation\":\"g\","
                "\"revision\":\"9\"}}");
        enqueue(stream_state, response(cancel_id));
    });

    auto stream = client.open_session_events();
    CHECK(stream);
    auto item = stream.value().next();
    CHECK(item);
    CHECK(item.value().has_value());
    CHECK_EQ(item.value()->sequence, 1U);
    CHECK_EQ(item.value()->value.event, std::string("future.event"));
    CHECK(item.value()->value.extra.find("future") != nullptr);

    auto ended = stream.value().cancel();
    CHECK(ended);
    CHECK_EQ(ended.value().reason, cmux::StreamEndReason::canceled);
    CHECK(stream.value().closed());
    server.join();
}
