#include "test.hpp"
#include "cmux/resource.hpp"

#include <string>
#include <array>
#include <utility>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>

TEST("machine catalog preserves remote owners and non-secret metadata") {
    for (const auto& [origin, expected] : std::array{
             std::pair{"local", cmux::MachineOrigin::local},
             std::pair{"cloud", cmux::MachineOrigin::cloud},
             std::pair{"ssh", cmux::MachineOrigin::ssh},
             std::pair{"server", cmux::MachineOrigin::server}}) {
        const std::string text = std::string("{\"id\":\"machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"name\":\"server\",\"origin\":\"") + origin +
            "\",\"status\":\"running\",\"connectable\":true,\"deleted\":false,\"recoverable\":false,\"platform\":{\"os\":\"linux\",\"arch\":null},\"capabilities\":[\"terminal\"]}";
        const auto parsed = cmux::Json::parse(text);
        CHECK(parsed);
        const auto decoded = cmux::detail::decode_value<cmux::MachineSnapshot>(parsed.value());
        CHECK(decoded);
        CHECK_EQ(decoded.value().origin, expected);
        CHECK(decoded.value().platform.has_value());
        CHECK_EQ(decoded.value().platform->os.value(), "linux");
        CHECK(!decoded.value().platform->arch.has_value());
        CHECK_EQ(decoded.value().capabilities, std::vector<std::string>{"terminal"});
    }
}

TEST("machine catalog preserves legacy defaults") {
    const auto parsed = cmux::Json::parse("{\"id\":\"machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"name\":\"local\",\"origin\":\"local\",\"status\":\"running\",\"connectable\":true,\"deleted\":false,\"recoverable\":false}");
    CHECK(parsed);
    const auto decoded = cmux::detail::decode_value<cmux::MachineSnapshot>(parsed.value());
    CHECK(decoded);
    CHECK(!decoded.value().platform.has_value());
    CHECK(decoded.value().capabilities.empty());
}


namespace {
constexpr const char* catalog_owner = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
struct CatalogState {
    std::mutex mutex;
    std::condition_variable ready;
    std::vector<cmux::Json> sent;
    std::deque<std::string> replies;
    bool closed = false;
};
class CatalogPeer final : public cmux::Transport {
public:
    explicit CatalogPeer(std::shared_ptr<CatalogState> state) : state_(std::move(state)) {}
    cmux::Result<void> send(std::string_view message, cmux::Timeout) override {
        auto decoded = cmux::Json::parse(message);
        if (!decoded) return decoded.error();
        auto request = std::move(decoded).value();
        const auto* params = request.find("params");
        const auto* id = request.find("id");
        const auto* operation = request.find("operation");
        if (!params || !id || !operation) return cmux::make_error(cmux::ErrorCode::protocol, "invalid test request");
        cmux::Json owner(cmux::Json::Object{{"id",catalog_owner},{"name","owner"},{"origin","local"},{"status","running"},{"connectable",true},{"deleted",false},{"recoverable",false}});
        const auto* catalog = params->find("catalog");
        if (catalog && catalog->is_bool() && catalog->as_bool().value()) {
            owner.as_object().value()->emplace("platform",cmux::Json::Object{{"os","linux"}});
        }
        cmux::Json result = operation->as_string().value() == "machine.list" ? cmux::Json(cmux::Json::Array{owner}) : owner;
        auto encoded = cmux::Json(cmux::Json::Object{{"protocol","cmux.protocol/2"},{"type","response"},{"id",*id},{"ok",true},{"result",std::move(result)}}).encode();
        if (!encoded) return encoded.error();
        { std::lock_guard lock(state_->mutex); state_->sent.push_back(std::move(request)); state_->replies.push_back(std::move(encoded).value()); }
        state_->ready.notify_one();
        return {};
    }
    cmux::Result<std::string> receive(cmux::Timeout timeout) override {
        std::unique_lock lock(state_->mutex);
        if (!state_->ready.wait_for(lock, timeout, [&]{ return state_->closed || !state_->replies.empty(); })) return cmux::make_error(cmux::ErrorCode::timeout,"test peer timed out");
        if (state_->replies.empty()) return cmux::make_error(cmux::ErrorCode::closed,"test peer closed");
        auto reply = std::move(state_->replies.front()); state_->replies.pop_front(); return reply;
    }
    void close() noexcept override {
        { std::lock_guard lock(state_->mutex); state_->closed = true; }
        state_->ready.notify_all();
    }
private:
    std::shared_ptr<CatalogState> state_;
};
}

TEST("cmux_next_machine_sdk_catalog_opt_in preserves defaults and captured owners") {
    auto state = std::make_shared<CatalogState>();
    cmux::ClientOptions options;
    options.transport_factory = [state]() -> cmux::Result<std::unique_ptr<cmux::Transport>> {
        return std::unique_ptr<cmux::Transport>(new CatalogPeer(state));
    };
    auto client = cmux::Client::connect(std::move(options)); CHECK(client);
    CHECK(client.value().machines());
    CHECK(client.value().machines(cmux::MachineReadOptions{true}));
    CHECK(client.value().machines(cmux::MachineReadOptions{}));
    auto id = cmux::MachineId::parse(catalog_owner); CHECK(id);
    auto owner = client.value().machine(id.value());
    CHECK(owner.refresh());
    auto rich = owner.refresh(cmux::MachineReadOptions{true}); CHECK(rich);
    CHECK(owner.refresh(cmux::MachineReadOptions{}));
    client.value().close();
    std::lock_guard lock(state->mutex);
    CHECK_EQ(state->sent.size(),std::size_t{6});
    for (std::size_t index=0; index<6; ++index) {
        cmux::Json::Object expected;
        if (index>=3) expected.emplace("machine",catalog_owner);
        if (index==1 || index==4) expected.emplace("catalog",true);
        CHECK_EQ(*state->sent[index].find("params"), cmux::Json(expected));
        CHECK(!state->sent[index].find("idempotency_key"));
    }
    CHECK(rich.value().platform.has_value());
    CHECK_EQ(rich.value().platform->os.value(), "linux");
}
