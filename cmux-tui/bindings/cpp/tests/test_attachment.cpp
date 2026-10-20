#include "test.hpp"

#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <future>
#include <initializer_list>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <type_traits>
#include <utility>
#include <variant>
#include <vector>

#include "cmux/raw/client.hpp"

namespace {

struct FakeState {
    std::mutex mutex;
    std::condition_variable changed;
    std::deque<std::string> incoming;
    std::vector<std::string> outgoing;
    std::optional<cmux::raw::Timeout> max_receive_wait;
    std::size_t receive_timeouts = 0;
    bool idle_timeout_proven = false;
    bool closed = false;
};

class FakeTransport final : public cmux::raw::Transport {
public:
    explicit FakeTransport(std::shared_ptr<FakeState> state)
        : state_(std::move(state)) {}

    cmux::raw::Result<void> send(std::string_view message, cmux::raw::Timeout) override {
        std::lock_guard lock(state_->mutex);
        if (state_->closed) {
            return cmux::raw::make_error(cmux::raw::ErrorCode::closed, "fake closed");
        }
        state_->outgoing.emplace_back(message);
        state_->changed.notify_all();
        return {};
    }

    cmux::raw::Result<std::string> receive(cmux::raw::Timeout timeout) override {
        std::unique_lock lock(state_->mutex);
        if (state_->max_receive_wait && timeout > *state_->max_receive_wait) {
            timeout = *state_->max_receive_wait;
        }
        if (!state_->changed.wait_for(lock, timeout, [this] {
                return state_->closed || !state_->incoming.empty();
            })) {
            ++state_->receive_timeouts;
            state_->changed.notify_all();
            return cmux::raw::make_error(cmux::raw::ErrorCode::timeout, "fake timeout");
        }
        if (state_->closed) {
            return cmux::raw::make_error(cmux::raw::ErrorCode::closed, "fake closed");
        }
        std::string message = std::move(state_->incoming.front());
        state_->incoming.pop_front();
        return message;
    }

    void close() noexcept override {
        std::lock_guard lock(state_->mutex);
        state_->closed = true;
        state_->changed.notify_all();
    }

private:
    std::shared_ptr<FakeState> state_;
};

cmux::raw::TransportFactory fake_factory(const std::shared_ptr<FakeState>& state) {
    return [state]() -> cmux::raw::Result<std::unique_ptr<cmux::raw::Transport>> {
        return std::unique_ptr<cmux::raw::Transport>(new FakeTransport(state));
    };
}

bool wait_for_outgoing(
    const std::shared_ptr<FakeState>& state,
    std::size_t count,
    std::chrono::milliseconds timeout = std::chrono::seconds(2)) {
    std::unique_lock lock(state->mutex);
    return state->changed.wait_for(lock, timeout, [&] {
        return state->closed || state->outgoing.size() >= count;
    }) &&
           state->outgoing.size() >= count;
}

bool wait_for_receive_timeouts(
    const std::shared_ptr<FakeState>& state,
    std::size_t count) {
    std::unique_lock lock(state->mutex);
    return state->changed.wait_for(
        lock,
        std::chrono::seconds(1),
        [&] { return state->receive_timeouts >= count; });
}

void enqueue(
    const std::shared_ptr<FakeState>& state,
    std::initializer_list<std::string_view> messages) {
    std::lock_guard lock(state->mutex);
    for (std::string_view message : messages) {
        state->incoming.emplace_back(message);
    }
    state->changed.notify_all();
}

void abort_fake(const std::shared_ptr<FakeState>& state) {
    std::lock_guard lock(state->mutex);
    state->closed = true;
    state->changed.notify_all();
}

std::vector<std::string> outgoing(const std::shared_ptr<FakeState>& state) {
    std::lock_guard lock(state->mutex);
    return state->outgoing;
}

constexpr std::string_view kOneSelfClient =
    R"({"id":1,"ok":true,"data":[{"attached":[],"client":44,"connected_seconds":1,"kind":null,"name":null,"self":true,"sizes":[],"transport":"unix"}]})";

bool respond_to_basic_bootstrap(const std::shared_ptr<FakeState>& state) {
    if (!wait_for_outgoing(state, 1)) {
        abort_fake(state);
        return false;
    }
    enqueue(state, {kOneSelfClient});
    if (!wait_for_outgoing(state, 2)) {
        abort_fake(state);
        return false;
    }
    enqueue(state, {R"({"id":2,"ok":true,"data":{}})"});
    return true;
}

cmux::raw::ClientOptions attachment_options(const std::shared_ptr<FakeState>& state) {
    cmux::raw::ClientOptions options;
    options.timeout = std::chrono::seconds(2);
    options.stream_transport_factory = fake_factory(state);
    return options;
}

}  // namespace

static_assert(!std::is_copy_constructible_v<cmux::raw::SurfaceAttachment>);
static_assert(!std::is_copy_assignable_v<cmux::raw::SurfaceAttachment>);
static_assert(std::is_nothrow_move_constructible_v<cmux::raw::SurfaceAttachment>);
static_assert(std::is_nothrow_move_assignable_v<cmux::raw::SurfaceAttachment>);
static_assert(std::is_same_v<cmux::raw::RenderAttachment, cmux::raw::SurfaceAttachment>);

TEST("render attachment selects self without diffing concurrent external clients") {
    auto state = std::make_shared<FakeState>();
    std::jthread server([state] {
        if (!wait_for_outgoing(state, 1)) {
            abort_fake(state);
            return;
        }
        enqueue(
            state,
            {R"({"id":1,"ok":true,"data":[{"attached":[7],"client":12,"connected_seconds":9,"kind":null,"name":null,"self":false,"sizes":[],"transport":"unix"},{"attached":[],"client":44,"connected_seconds":1,"kind":null,"name":null,"self":true,"sizes":[],"transport":"unix"},{"attached":[7],"client":999,"connected_seconds":0,"kind":null,"name":null,"self":false,"sizes":[],"transport":"ws"}]})"});
        if (!wait_for_outgoing(state, 2)) {
            abort_fake(state);
            return;
        }
        enqueue(
            state,
            {
                R"({"event":"client-attached","client":1000,"kind":null,"name":null,"transport":"unix"})",
                R"({"id":2,"ok":true,"data":{}})",
            });
    });

    cmux::raw::AttachSurfaceRequest request{.surface = cmux::raw::Id{7}};
    auto opened =
        cmux::raw::open_render_attachment(request, attachment_options(state));
    server.join();
    if (!opened) {
        test::fail("opened", __FILE__, __LINE__, opened.error().message);
    }
    auto attachment = std::move(opened).value();
    CHECK_EQ(attachment.surface(), cmux::raw::Id{7});
    CHECK_EQ(attachment.client_id(), 44U);

    auto external = attachment.next(std::chrono::milliseconds(20));
    CHECK(external);
    CHECK_EQ(external.value().name(), std::string_view("client-attached"));
    const auto* attached =
        std::get_if<cmux::raw::ClientAttachedEvent>(&external.value().value);
    CHECK(attached != nullptr);
    CHECK_EQ(attached->client, 1000U);

    const auto sent = outgoing(state);
    CHECK_EQ(sent.size(), 2U);
    auto discover = cmux::raw::Json::parse(sent[0]);
    auto attach = cmux::raw::Json::parse(sent[1]);
    CHECK(discover);
    CHECK(attach);
    CHECK_EQ(
        discover.value().find("cmd")->as_string().value(),
        std::string_view("list-clients"));
    CHECK_EQ(
        attach.value().find("cmd")->as_string().value(),
        std::string_view("attach-surface"));
    CHECK_EQ(
        attach.value().find("mode")->as_string().value(),
        std::string_view("render"));
}

TEST("acknowledged attachment has no implicit idle deadline") {
    auto state = std::make_shared<FakeState>();
    constexpr auto client_timeout = std::chrono::milliseconds(20);
    constexpr auto open_timeout = std::chrono::milliseconds(200);
    constexpr std::size_t idle_timeouts = 11;
    static_assert(client_timeout * idle_timeouts > open_timeout);
    state->max_receive_wait = client_timeout;
    auto options = attachment_options(state);
    options.timeout = client_timeout;
    std::promise<void> opened_signal;
    auto opened_ready = opened_signal.get_future();
    std::jthread server([state, opened_ready = std::move(opened_ready)] {
        if (!respond_to_basic_bootstrap(state)) {
            return;
        }
        (void)opened_ready.wait_for(std::chrono::seconds(1));
        std::size_t timeout_target = idle_timeouts;
        {
            std::lock_guard lock(state->mutex);
            timeout_target += state->receive_timeouts;
        }
        const bool idle_timeout_proven =
            wait_for_receive_timeouts(state, timeout_target);
        {
            std::lock_guard lock(state->mutex);
            state->idle_timeout_proven = idle_timeout_proven;
        }
        enqueue(state, {R"({"event":"delayed"})"});
    });

    auto opened = cmux::raw::open_render_attachment(
        cmux::raw::AttachSurfaceRequest{.surface = cmux::raw::Id{7}},
        std::move(options),
        cmux::raw::RequestOptions{
            .timeout = open_timeout,
        });
    CHECK(opened);
    auto attachment = std::move(opened).value();
    opened_signal.set_value();
    auto event = attachment.next();
    CHECK(event);
    CHECK_EQ(event.value().name(), std::string_view("delayed"));
    CHECK(!attachment.closed());
    std::lock_guard lock(state->mutex);
    CHECK(state->idle_timeout_proven);
}

TEST("render attachment routes sizing commands and preserves event order") {
    auto decoy_control = std::make_shared<FakeState>();
    auto attachment_state = std::make_shared<FakeState>();
    cmux::raw::ClientOptions options = attachment_options(attachment_state);
    options.transport_factory = fake_factory(decoy_control);

    std::jthread server([attachment_state] {
        if (!wait_for_outgoing(attachment_state, 1)) {
            abort_fake(attachment_state);
            return;
        }
        enqueue(attachment_state, {kOneSelfClient});
        if (!wait_for_outgoing(attachment_state, 2)) {
            abort_fake(attachment_state);
            return;
        }
        enqueue(
            attachment_state,
            {
                R"({"event":"pre-ack","order":1})",
                R"({"id":2,"ok":true,"data":{}})",
            });
        if (!wait_for_outgoing(attachment_state, 3)) {
            abort_fake(attachment_state);
            return;
        }
        enqueue(
            attachment_state,
            {
                R"({"event":"during-resize","order":2})",
                R"({"id":3,"ok":true,"data":{"accepted":true,"reservation_id":77}})",
            });
        if (!wait_for_outgoing(attachment_state, 4)) {
            abort_fake(attachment_state);
            return;
        }
        enqueue(attachment_state, {R"({"id":4,"ok":true,"data":{}})"});
        if (!wait_for_outgoing(attachment_state, 5)) {
            abort_fake(attachment_state);
            return;
        }
        enqueue(attachment_state, {R"({"id":5,"ok":true,"data":{}})"});
    });

    cmux::raw::AttachSurfaceRequest request{
        .cols = std::uint16_t{100},
        .rows = std::uint16_t{30},
        .surface = cmux::raw::Id{7},
    };
    auto opened = cmux::raw::RenderAttachment::connect(request, std::move(options));
    CHECK(opened);
    auto attachment = std::move(opened).value();

    auto resized = attachment.resize(120, 40);
    CHECK(resized);
    CHECK(resized.value().accepted);
    CHECK_EQ(resized.value().reservation_id, std::optional<std::uint64_t>(77));
    CHECK(attachment.set_sizing(true, true));
    CHECK(attachment.release_size());
    server.join();

    auto before_ack = attachment.next(std::chrono::milliseconds(20));
    auto during_resize = attachment.next(std::chrono::milliseconds(20));
    CHECK(before_ack);
    CHECK(during_resize);
    CHECK_EQ(before_ack.value().name(), std::string_view("pre-ack"));
    CHECK_EQ(during_resize.value().name(), std::string_view("during-resize"));

    CHECK(outgoing(decoy_control).empty());
    const auto sent = outgoing(attachment_state);
    CHECK_EQ(sent.size(), 5U);
    auto resize = cmux::raw::Json::parse(sent[2]);
    auto sizing = cmux::raw::Json::parse(sent[3]);
    auto release = cmux::raw::Json::parse(sent[4]);
    CHECK(resize);
    CHECK(sizing);
    CHECK(release);
    CHECK_EQ(
        resize.value().find("cmd")->as_string().value(),
        std::string_view("resize-surface"));
    CHECK_EQ(resize.value().find("surface")->as_uint64().value(), 7U);
    CHECK_EQ(resize.value().find("cols")->as_uint64().value(), 120U);
    CHECK_EQ(resize.value().find("rows")->as_uint64().value(), 40U);
    CHECK_EQ(
        sizing.value().find("cmd")->as_string().value(),
        std::string_view("set-client-sizing"));
    CHECK_EQ(sizing.value().find("client")->as_uint64().value(), 44U);
    CHECK(sizing.value().find("enabled")->as_bool().value());
    CHECK(sizing.value().find("exclusive")->as_bool().value());
    CHECK_EQ(
        release.value().find("cmd")->as_string().value(),
        std::string_view("release-surface-size"));
    CHECK_EQ(release.value().find("surface")->as_uint64().value(), 7U);
}

TEST("render attachment enforces its buffer bound before attach acknowledgement") {
    auto state = std::make_shared<FakeState>();
    auto options = attachment_options(state);
    options.max_buffered_stream_events = 1;
    std::jthread server([state] {
        if (!wait_for_outgoing(state, 1)) {
            abort_fake(state);
            return;
        }
        enqueue(state, {kOneSelfClient});
        if (!wait_for_outgoing(state, 2)) {
            abort_fake(state);
            return;
        }
        enqueue(
            state,
            {
                R"({"event":"first"})",
                R"({"event":"second"})",
                R"({"id":2,"ok":true,"data":{}})",
            });
    });

    auto opened = cmux::raw::open_render_attachment(
        cmux::raw::AttachSurfaceRequest{.surface = cmux::raw::Id{7}},
        std::move(options));
    server.join();
    CHECK(!opened);
    CHECK_EQ(opened.error().code, cmux::raw::ErrorCode::protocol);
    CHECK_EQ(
        opened.error().message,
        std::string("attachment event buffer limit exceeded"));
    std::lock_guard lock(state->mutex);
    CHECK(state->closed);
}

TEST("render attachment enforces its buffer bound during commands") {
    auto state = std::make_shared<FakeState>();
    auto options = attachment_options(state);
    options.max_buffered_stream_events = 1;
    std::jthread server([state] {
        if (!respond_to_basic_bootstrap(state)) {
            return;
        }
        if (!wait_for_outgoing(state, 3)) {
            abort_fake(state);
            return;
        }
        enqueue(
            state,
            {
                R"({"event":"first"})",
                R"({"event":"second"})",
                R"({"id":3,"ok":true,"data":{"accepted":true}})",
            });
    });

    auto opened = cmux::raw::open_render_attachment(
        cmux::raw::AttachSurfaceRequest{.surface = cmux::raw::Id{7}},
        std::move(options));
    CHECK(opened);
    auto attachment = std::move(opened).value();
    auto resized = attachment.resize(80, 24);
    server.join();
    CHECK(!resized);
    CHECK_EQ(resized.error().code, cmux::raw::ErrorCode::protocol);
    CHECK(attachment.closed());

    auto buffered = attachment.next(std::chrono::milliseconds(20));
    CHECK(buffered);
    CHECK_EQ(buffered.value().name(), std::string_view("first"));
    auto overflow = attachment.next(std::chrono::milliseconds(20));
    CHECK(!overflow);
    CHECK_EQ(overflow.error().code, cmux::raw::ErrorCode::protocol);
}

TEST("render attachment close unblocks event and command waiters") {
    auto state = std::make_shared<FakeState>();
    std::jthread server([state] { (void)respond_to_basic_bootstrap(state); });
    auto opened = cmux::raw::open_render_attachment(
        cmux::raw::AttachSurfaceRequest{.surface = cmux::raw::Id{7}},
        attachment_options(state));
    server.join();
    CHECK(opened);
    auto attachment = std::move(opened).value();

    cmux::raw::Result<cmux::raw::Event> event =
        cmux::raw::make_error(cmux::raw::ErrorCode::protocol, "not started");
    cmux::raw::Result<cmux::raw::ResizeSurfaceResult> resized =
        cmux::raw::make_error(cmux::raw::ErrorCode::protocol, "not started");
    std::promise<void> event_started;
    auto event_ready = event_started.get_future();
    std::thread event_waiter([&] {
        event_started.set_value();
        event = attachment.next(std::chrono::seconds(30));
    });
    event_ready.wait();
    std::thread command_waiter([&] { resized = attachment.resize(100, 30); });
    CHECK(wait_for_outgoing(state, 3));

    attachment.close();
    event_waiter.join();
    command_waiter.join();
    CHECK(attachment.closed());
    CHECK(!event);
    CHECK(!resized);
    CHECK_EQ(event.error().code, cmux::raw::ErrorCode::closed);
    CHECK_EQ(resized.error().code, cmux::raw::ErrorCode::closed);
}
