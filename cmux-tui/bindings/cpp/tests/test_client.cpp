#include "test.hpp"

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <initializer_list>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>

#include "cmux/client.hpp"
#include "cmux/client_core.hpp"

namespace {

struct FakeState {
    std::mutex mutex;
    std::condition_variable ready;
    std::deque<std::string> incoming;
    std::vector<std::string> outgoing;
    bool closed = false;
};

class FakeTransport final : public cmux::Transport {
public:
    explicit FakeTransport(std::shared_ptr<FakeState> state) : state_(std::move(state)) {}

    cmux::Result<void> send(std::string_view message, cmux::Timeout) override {
        std::lock_guard lock(state_->mutex);
        if (state_->closed) {
            return cmux::make_error(cmux::ErrorCode::closed, "fake closed");
        }
        state_->outgoing.emplace_back(message);
        state_->ready.notify_all();
        return {};
    }

    cmux::Result<std::string> receive(std::chrono::milliseconds timeout) override {
        std::unique_lock lock(state_->mutex);
        if (!state_->ready.wait_for(lock, timeout, [this] {
                return state_->closed || !state_->incoming.empty();
            })) {
            return cmux::make_error(cmux::ErrorCode::timeout, "fake timeout");
        }
        if (state_->closed) {
            return cmux::make_error(cmux::ErrorCode::closed, "fake closed");
        }
        std::string message = std::move(state_->incoming.front());
        state_->incoming.pop_front();
        return message;
    }

    void close() noexcept override {
        std::lock_guard lock(state_->mutex);
        state_->closed = true;
        state_->ready.notify_all();
    }

private:
    std::shared_ptr<FakeState> state_;
};

cmux::TransportFactory fake_factory(const std::shared_ptr<FakeState>& state) {
    return [state]() -> cmux::Result<std::unique_ptr<cmux::Transport>> {
        return std::unique_ptr<cmux::Transport>(new FakeTransport(state));
    };
}

void wait_for_send(const std::shared_ptr<FakeState>& state) {
    std::unique_lock lock(state->mutex);
    state->ready.wait(lock, [&] { return !state->outgoing.empty(); });
}

std::string identify_response(
    std::uint64_t id,
    std::uint32_t protocol = 10,
    std::initializer_list<std::string_view> capabilities = {}) {
    cmux::Json::Array encoded_capabilities;
    encoded_capabilities.reserve(capabilities.size());
    for (const auto capability : capabilities) {
        encoded_capabilities.emplace_back(std::string(capability));
    }
    cmux::Json::Object data;
    data.emplace("app", cmux::Json("cmux-tui"));
    data.emplace("capabilities", cmux::Json(std::move(encoded_capabilities)));
    data.emplace("daemon_handoff", cmux::Json(std::uint64_t{1}));
    data.emplace("generation", cmux::Json("test-generation"));
    data.emplace("pid", cmux::Json(123U));
    data.emplace("protocol", cmux::Json(protocol));
    data.emplace("registry_id", cmux::Json("test-registry"));
    data.emplace("session", cmux::Json("test-session"));
    data.emplace("terminal_revision", cmux::Json(std::uint64_t{4}));
    data.emplace("version", cmux::Json("test"));
    data.emplace("workspace_revision", cmux::Json(std::uint64_t{5}));

    cmux::Json::Object response;
    response.emplace("data", cmux::Json(std::move(data)));
    response.emplace("id", cmux::Json(id));
    response.emplace("ok", cmux::Json(true));
    return cmux::Json(std::move(response)).encode().value();
}

void enqueue(
    const std::shared_ptr<FakeState>& state,
    std::string message) {
    std::lock_guard lock(state->mutex);
    state->incoming.push_back(std::move(message));
    state->ready.notify_all();
}

}  // namespace

TEST("ClientCore sends command envelopes and returns typed JSON data") {
    auto state = std::make_shared<FakeState>();
    cmux::ClientOptions options;
    options.transport_factory = fake_factory(state);
    auto client = cmux::detail::ClientCore::connect(std::move(options));
    CHECK(client);

    std::thread server([state] {
        wait_for_send(state);
        std::lock_guard lock(state->mutex);
        state->incoming.emplace_back(
            R"({"id":1,"ok":true,"data":{"protocol":10,"large":18446744073709551615}})");
        state->ready.notify_all();
    });
    auto response = client.value().request("identify");
    server.join();
    CHECK(response);
    CHECK_EQ(response.value().find("protocol")->as_uint64().value(), 10U);
    CHECK_EQ(
        response.value().find("large")->as_uint64().value(),
        std::numeric_limits<std::uint64_t>::max());

    std::lock_guard lock(state->mutex);
    auto envelope = cmux::Json::parse(state->outgoing.front());
    CHECK(envelope);
    CHECK_EQ(envelope.value().find("cmd")->as_string().value(), std::string_view("identify"));
    CHECK_EQ(envelope.value().find("id")->as_uint64().value(), 1U);
}

TEST("ClientCore preserves server command errors") {
    auto state = std::make_shared<FakeState>();
    cmux::ClientOptions options;
    options.transport_factory = fake_factory(state);
    auto client = cmux::detail::ClientCore::connect(std::move(options));
    CHECK(client);
    enqueue(state, identify_response(1));
    enqueue(state, R"({"id":2,"ok":false,"error":"no such surface"})");
    auto response = client.value().request("read-screen");
    CHECK(!response);
    CHECK_EQ(response.error().code, cmux::ErrorCode::command);
    CHECK_EQ(response.error().message, std::string("no such surface"));
    CHECK(response.error().response != nullptr);
}

TEST("ClientCore enforces per-request timeouts") {
    auto state = std::make_shared<FakeState>();
    cmux::ClientOptions options;
    options.timeout = std::chrono::seconds(30);
    options.transport_factory = fake_factory(state);
    auto client = cmux::detail::ClientCore::connect(std::move(options));
    CHECK(client);

    enqueue(state, identify_response(1));
    auto response =
        client.value().request("ping", {}, std::chrono::milliseconds(5));
    CHECK(!response);
    CHECK_EQ(response.error().code, cmux::ErrorCode::timeout);
}

TEST("ClientCore close unblocks a pending receive") {
    auto state = std::make_shared<FakeState>();
    cmux::ClientOptions options;
    options.timeout = std::chrono::seconds(30);
    options.transport_factory = fake_factory(state);
    auto client_result = cmux::detail::ClientCore::connect(std::move(options));
    CHECK(client_result);
    auto client = std::move(client_result).value();

    cmux::Result<cmux::Json> response =
        cmux::make_error(cmux::ErrorCode::protocol, "not started");
    std::thread reader([&] { response = client.request("ping"); });
    wait_for_send(state);
    client.close();
    reader.join();
    CHECK(!response);
    CHECK_EQ(response.error().code, cmux::ErrorCode::closed);
}

TEST("ClientCore rejects commands newer than the negotiated protocol before target write") {
    auto state = std::make_shared<FakeState>();
    cmux::ClientOptions options;
    options.transport_factory = fake_factory(state);
    auto client = cmux::detail::ClientCore::connect(std::move(options));
    CHECK(client);
    enqueue(state, R"({"id":1,"ok":true,"data":{"protocol":8}})");

    auto response = client.value().request("new-pane");
    CHECK(!response);
    CHECK_EQ(response.error().code, cmux::ErrorCode::unsupported);
    CHECK_EQ(
        response.error().message,
        std::string("command 'new-pane' requires protocol 9; server uses protocol 8"));

    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 1U);
    auto envelope = cmux::Json::parse(state->outgoing.front());
    CHECK(envelope);
    CHECK_EQ(
        envelope.value().find("cmd")->as_string().value(),
        std::string_view("identify"));
}

TEST("ClientCore rejects missing command capabilities before target write") {
    auto state = std::make_shared<FakeState>();
    cmux::ClientOptions options;
    options.transport_factory = fake_factory(state);
    auto client = cmux::detail::ClientCore::connect(std::move(options));
    CHECK(client);
    enqueue(state, identify_response(1));

    auto response = client.value().request("create-workspace");
    CHECK(!response);
    CHECK_EQ(response.error().code, cmux::ErrorCode::unsupported);
    CHECK_EQ(
        response.error().message,
        std::string(
            "command 'create-workspace' requires capability "
            "'workspace-registry-v1'"));

    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 1U);
}

TEST("ClientCore gates present fields by protocol including explicit null") {
    auto state = std::make_shared<FakeState>();
    cmux::ClientOptions options;
    options.transport_factory = fake_factory(state);
    auto client = cmux::detail::ClientCore::connect(std::move(options));
    CHECK(client);
    enqueue(state, identify_response(1, 6));

    cmux::Json::Object parameters;
    parameters.emplace("paste", cmux::Json(nullptr));
    auto response = client.value().request("send", std::move(parameters));
    CHECK(!response);
    CHECK_EQ(response.error().code, cmux::ErrorCode::unsupported);
    CHECK_EQ(
        response.error().message,
        std::string(
            "command field 'send.paste' requires protocol 7; "
            "server uses protocol 6"));

    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 1U);
}

TEST("ClientCore gates stream fields by capability before opening target transport") {
    auto control = std::make_shared<FakeState>();
    auto stream = std::make_shared<FakeState>();
    cmux::ClientOptions options;
    options.transport_factory = fake_factory(control);
    options.stream_transport_factory = fake_factory(stream);
    auto client = cmux::detail::ClientCore::connect(std::move(options));
    CHECK(client);
    enqueue(control, identify_response(1));

    cmux::Json::Object parameters;
    parameters.emplace("cols", cmux::Json(80U));
    parameters.emplace("rows", cmux::Json(24U));
    auto opened =
        client.value().open_stream("attach-surface", std::move(parameters), "detached");
    CHECK(!opened);
    CHECK_EQ(opened.error().code, cmux::ErrorCode::unsupported);
    CHECK_EQ(
        opened.error().message,
        std::string(
            "command field 'attach-surface.cols' requires capability "
            "'attach-initial-size'"));

    std::lock_guard control_lock(control->mutex);
    CHECK_EQ(control->outgoing.size(), 1U);
    std::lock_guard stream_lock(stream->mutex);
    CHECK(stream->outgoing.empty());
}

TEST("ClientCore caches explicit identify for subsequent typed commands") {
    auto state = std::make_shared<FakeState>();
    cmux::ClientOptions options;
    options.transport_factory = fake_factory(state);
    auto client = cmux::detail::ClientCore::connect(std::move(options));
    CHECK(client);
    enqueue(state, identify_response(1));
    enqueue(
        state,
        R"({"id":2,"ok":true,"data":{"ok":true,"protocol":10,"version":"test"}})");

    auto identified = client.value().request("identify");
    CHECK(identified);
    auto ping = client.value().request("ping");
    CHECK(ping);

    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 2U);
    auto target = cmux::Json::parse(state->outgoing.back());
    CHECK(target);
    CHECK_EQ(
        target.value().find("cmd")->as_string().value(),
        std::string_view("ping"));
}

TEST("ClientCore leaves unknown raw commands available for forward compatibility") {
    auto state = std::make_shared<FakeState>();
    cmux::ClientOptions options;
    options.transport_factory = fake_factory(state);
    auto client = cmux::detail::ClientCore::connect(std::move(options));
    CHECK(client);
    enqueue(state, R"({"id":1,"ok":true,"data":{"future":true}})");

    auto response = client.value().request("future-command", {{"value", cmux::Json(9U)}});
    CHECK(response);

    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 1U);
    auto envelope = cmux::Json::parse(state->outgoing.front());
    CHECK(envelope);
    CHECK_EQ(
        envelope.value().find("cmd")->as_string().value(),
        std::string_view("future-command"));
    CHECK_EQ(envelope.value().find("id")->as_uint64().value(), 1U);
}

TEST("Client denies every provider-authority method before transport write") {
    auto state = std::make_shared<FakeState>();
    cmux::ClientOptions options;
    options.transport_factory = fake_factory(state);
    CHECK(options.authorities.allows("control"));
    CHECK(options.authorities.allows("frontend"));
    CHECK(options.authorities.allows("local-admin"));
    CHECK(!options.authorities.allows("provider-authority"));
    auto connected = cmux::Client::connect(std::move(options));
    CHECK(connected);
    auto client = std::move(connected).value();

    auto marked = client.mark_workspaces_provider_managed(
        cmux::MarkWorkspacesProviderManagedRequest{.authority = "provider.test"});
    auto closed = client.close_provider_managed_workspace(
        cmux::CloseProviderManagedWorkspaceRequest{
            .authority = "provider.test",
            .key = "workspace-key",
            .workspace = cmux::Id{7},
        });
    auto renamed = client.rename_provider_managed_workspace(
        cmux::RenameProviderManagedWorkspaceRequest{
            .authority = "provider.test",
            .key = "workspace-key",
            .name = "renamed",
            .workspace = cmux::Id{7},
        });
    CHECK(!marked);
    CHECK(!closed);
    CHECK(!renamed);
    CHECK_EQ(marked.error().code, cmux::ErrorCode::authority);
    CHECK_EQ(closed.error().code, cmux::ErrorCode::authority);
    CHECK_EQ(renamed.error().code, cmux::ErrorCode::authority);
    CHECK_EQ(marked.error().code_name(), std::string("authority"));
    {
        std::lock_guard lock(state->mutex);
        CHECK(state->outgoing.empty());
    }

    enqueue(state, identify_response(1));
    enqueue(
        state,
        R"({"id":2,"ok":true,"data":{"ok":true,"protocol":10,"version":"test"}})");
    auto ping = client.ping();
    CHECK(ping);
    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 2U);
    auto identify = cmux::Json::parse(state->outgoing.front());
    CHECK(identify);
    CHECK_EQ(identify.value().find("id")->as_uint64().value(), 1U);
    CHECK_EQ(
        identify.value().find("cmd")->as_string().value(),
        std::string_view("identify"));
    auto envelope = cmux::Json::parse(state->outgoing.back());
    CHECK(envelope);
    CHECK_EQ(envelope.value().find("id")->as_uint64().value(), 2U);
    CHECK_EQ(
        envelope.value().find("cmd")->as_string().value(),
        std::string_view("ping"));
}

TEST("Client provider-authority opt-in permits the transport write") {
    auto state = std::make_shared<FakeState>();
    cmux::ClientOptions options;
    options.transport_factory = fake_factory(state);
    options.authorities.provider_authority = true;
    auto connected = cmux::Client::connect(std::move(options));
    CHECK(connected);
    auto client = std::move(connected).value();

    enqueue(
        state,
        identify_response(
            1, 10, {"provider-managed-workspace-authority-v2"}));
    enqueue(state, R"({"id":2,"ok":true,"data":{}})");
    auto marked = client.mark_workspaces_provider_managed(
        cmux::MarkWorkspacesProviderManagedRequest{.authority = "provider.test"});
    CHECK(marked);

    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->outgoing.size(), 2U);
    auto envelope = cmux::Json::parse(state->outgoing.back());
    CHECK(envelope);
    CHECK_EQ(
        envelope.value().find("cmd")->as_string().value(),
        std::string_view("mark-workspaces-provider-managed"));
}

TEST("stream open retains events arriving before the command response") {
    auto control = std::make_shared<FakeState>();
    auto stream = std::make_shared<FakeState>();
    cmux::ClientOptions options;
    options.transport_factory = fake_factory(control);
    options.stream_transport_factory = fake_factory(stream);
    auto client = cmux::detail::ClientCore::connect(std::move(options));
    CHECK(client);
    enqueue(control, identify_response(1));
    std::thread server([stream] {
        wait_for_send(stream);
        std::lock_guard lock(stream->mutex);
        stream->incoming.emplace_back(R"({"event":"vt-state","data":"AA=="})");
        stream->incoming.emplace_back(R"({"id":2,"ok":true,"data":{}})");
        stream->incoming.emplace_back(R"({"event":"mystery-future-event","x":1})");
        stream->incoming.emplace_back(R"({"event":"detached"})");
        stream->ready.notify_all();
    });
    auto opened = client.value().open_stream("attach-surface", {}, "detached");
    CHECK(opened);
    auto event_stream = std::move(opened).value();
    auto first = event_stream.next();
    CHECK(first);
    CHECK_EQ(first.value().find("event")->as_string().value(), std::string_view("vt-state"));
    auto unknown = event_stream.next();
    CHECK(unknown);
    CHECK_EQ(
        unknown.value().find("event")->as_string().value(),
        std::string_view("mystery-future-event"));
    CHECK_EQ(unknown.value().find("x")->as_uint64().value(), 1U);
    auto terminal = event_stream.next();
    CHECK(terminal);
    CHECK_EQ(terminal.value().find("event")->as_string().value(), std::string_view("detached"));
    CHECK(!event_stream.next());
    server.join();
}

TEST("stream close unblocks a pending next") {
    auto control = std::make_shared<FakeState>();
    auto stream_state = std::make_shared<FakeState>();
    cmux::ClientOptions options;
    options.transport_factory = fake_factory(control);
    options.stream_transport_factory = fake_factory(stream_state);
    auto client = cmux::detail::ClientCore::connect(std::move(options));
    CHECK(client);
    enqueue(control, identify_response(1));
    std::thread server([stream_state] {
        wait_for_send(stream_state);
        std::lock_guard lock(stream_state->mutex);
        stream_state->incoming.emplace_back(R"({"id":2,"ok":true,"data":{}})");
        stream_state->ready.notify_all();
    });
    auto opened = client.value().open_stream("subscribe");
    server.join();
    CHECK(opened);
    auto event_stream = std::move(opened).value();
    cmux::Result<cmux::Json> next =
        cmux::make_error(cmux::ErrorCode::protocol, "not started");
    std::thread reader([&] { next = event_stream.next(std::chrono::seconds(30)); });
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    event_stream.close();
    reader.join();
    CHECK(!next);
    CHECK_EQ(next.error().code, cmux::ErrorCode::closed);
}

TEST("stream next enforces its read timeout without closing the stream") {
    auto control = std::make_shared<FakeState>();
    auto stream_state = std::make_shared<FakeState>();
    cmux::ClientOptions options;
    options.transport_factory = fake_factory(control);
    options.stream_transport_factory = fake_factory(stream_state);
    auto client = cmux::detail::ClientCore::connect(std::move(options));
    CHECK(client);
    enqueue(control, identify_response(1));
    std::thread server([stream_state] {
        wait_for_send(stream_state);
        std::lock_guard lock(stream_state->mutex);
        stream_state->incoming.emplace_back(R"({"id":2,"ok":true,"data":{}})");
        stream_state->ready.notify_all();
    });
    auto opened = client.value().open_stream("subscribe");
    server.join();
    CHECK(opened);
    auto event_stream = std::move(opened).value();
    auto next = event_stream.next(std::chrono::milliseconds(5));
    CHECK(!next);
    CHECK_EQ(next.error().code, cmux::ErrorCode::timeout);
    CHECK(!event_stream.closed());
    event_stream.close();
}
