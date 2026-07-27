#include <cstdlib>
#include <deque>
#include <functional>
#include <iostream>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "cmux/codec.hpp"
#include "cmux/json.hpp"
#include "cmux/transport.hpp"
#include "cmux_example/frontend.hpp"

namespace {

class TestFailure final : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

#define CHECK(condition)                                                          \
    do {                                                                          \
        if (!(condition)) {                                                        \
            throw TestFailure(                                                     \
                std::string("CHECK failed at line ") + std::to_string(__LINE__) + \
                ": " #condition);                                                 \
        }                                                                         \
    } while (false)

template <typename T>
cmux::Json encode_or_throw(const T& value) {
    auto encoded = cmux::encode_value(value);
    if (!encoded) {
        throw TestFailure("encode failed: " + encoded.error().message);
    }
    return std::move(encoded).value();
}

std::string json_or_throw(cmux::Json value) {
    auto encoded = value.encode();
    if (!encoded) {
        throw TestFailure("JSON encode failed: " + encoded.error().message);
    }
    return std::move(encoded).value();
}

template <typename T>
std::string success_response(std::uint64_t id, const T& value) {
    cmux::Json::Object response;
    response.emplace("id", cmux::Json(id));
    response.emplace("ok", cmux::Json(true));
    response.emplace("data", encode_or_throw(value));
    return json_or_throw(cmux::Json(std::move(response)));
}

template <typename T>
std::string event_message(const T& event) {
    return json_or_throw(encode_or_throw(event));
}

cmux::IdentifyResult identify_result() {
    cmux::IdentifyResult identify;
    identify.capabilities = std::vector<std::string>{"attach-initial-size"};
    identify.generation = "generation-1";
    identify.pid = 1234;
    identify.protocol = 10;
    identify.registry_id = "registry-1";
    identify.session = "test";
    identify.terminal_revision = 4;
    identify.version = "0.1-test";
    identify.workspace_revision = 5;
    return identify;
}

cmux::Tree topology(cmux::Id surface) {
    cmux::Tab tab;
    tab.dead = false;
    tab.kind = cmux::TabKind::pty;
    tab.surface = surface;
    tab.title = "shell";

    cmux::LivePane live;
    live.active_tab = 0;
    live.id = cmux::Id{30};
    live.tabs.push_back(std::move(tab));

    cmux::Pane pane;
    pane.value = std::move(live);

    cmux::Layout layout;
    layout.value = cmux::LayoutLeaf{cmux::Id{30}};

    cmux::Screen screen;
    screen.active = true;
    screen.active_pane = cmux::Id{30};
    screen.id = cmux::Id{20};
    screen.layout = std::move(layout);
    screen.panes.push_back(std::move(pane));

    cmux::Workspace workspace;
    workspace.active = true;
    workspace.id = cmux::Id{10};
    workspace.name = "workspace";
    workspace.screens.push_back(std::move(screen));

    cmux::Tree tree;
    tree.generation = "generation-1";
    tree.workspaces.push_back(std::move(workspace));
    return tree;
}

cmux::ClientInfo control_client(std::uint64_t id) {
    cmux::ClientInfo client;
    client.client = id;
    client.self = true;
    client.transport = cmux::ClientTransport::unix;
    return client;
}

cmux::ClientInfo render_client(
    std::uint64_t id,
    cmux::Id surface,
    std::uint16_t columns,
    std::uint16_t rows) {
    cmux::ClientInfo client;
    client.attached.push_back(surface);
    client.client = id;
    client.self = false;
    client.transport = cmux::ClientTransport::unix;
    client.sizes.push_back(cmux::ClientSize{
        .cols = columns,
        .rows = rows,
        .size_participating = true,
        .surface = surface,
    });
    return client;
}

cmux::RenderCursor cursor(std::uint16_t x = 0, std::uint16_t y = 0) {
    return cmux::RenderCursor{
        .blink = false,
        .color = std::nullopt,
        .style = cmux::CursorStyle::block,
        .visible = true,
        .x = x,
        .y = y,
    };
}

cmux::RenderRow row(std::uint32_t index, std::string text) {
    cmux::RenderRun run;
    run.text = std::move(text);
    return cmux::RenderRow{
        .row = index,
        .runs = {std::move(run)},
    };
}

cmux::RenderStateEvent state_event(
    cmux::Id surface,
    std::vector<std::string> lines) {
    cmux::RenderStateEvent event;
    event.cursor = cursor();
    event.default_bg = cmux::ColorHex{"#000000"};
    event.default_fg = cmux::ColorHex{"#ffffff"};
    event.scrollback_rows = 2;
    event.size = cmux::Size{
        .cols = 12,
        .rows = static_cast<std::uint16_t>(lines.size()),
    };
    event.surface = surface;
    for (std::uint32_t index = 0; index < lines.size(); ++index) {
        event.rows.push_back(row(index, std::move(lines[index])));
    }
    return event;
}

cmux::RenderDeltaEvent delta_event(
    cmux::Id surface,
    std::uint32_t index,
    std::string text) {
    cmux::RenderDeltaEvent event;
    event.cursor = cursor(1, static_cast<std::uint16_t>(index));
    event.full = false;
    event.rows.push_back(row(index, std::move(text)));
    event.surface = surface;
    return event;
}

cmux::RenderDeltaEvent full_delta_event(
    cmux::Id surface,
    std::uint16_t columns,
    std::vector<std::string> lines) {
    cmux::RenderDeltaEvent event;
    event.cursor = cursor();
    event.full = true;
    event.size = cmux::Size{
        .cols = columns,
        .rows = static_cast<std::uint16_t>(lines.size()),
    };
    event.surface = surface;
    for (std::uint32_t index = 0; index < lines.size(); ++index) {
        event.rows.push_back(row(index, std::move(lines[index])));
    }
    return event;
}

struct FakeEndpoint;

using SendHandler =
    std::function<cmux::Result<void>(const cmux::Json&, FakeEndpoint&)>;

struct FakeEndpoint {
    std::deque<std::string> incoming;
    std::vector<std::string> outgoing;
    SendHandler on_send;
    cmux::Error empty_error =
        cmux::make_error(cmux::ErrorCode::timeout, "no scripted message");
    bool closed = false;
};

class FakeTransport final : public cmux::Transport {
public:
    explicit FakeTransport(std::shared_ptr<FakeEndpoint> endpoint)
        : endpoint_(std::move(endpoint)) {}

    cmux::Result<void> send(
        std::string_view message,
        cmux::Timeout) override {
        if (endpoint_->closed) {
            return cmux::make_error(cmux::ErrorCode::closed, "fake transport closed");
        }
        endpoint_->outgoing.emplace_back(message);
        auto parsed = cmux::Json::parse(message);
        if (!parsed) {
            return std::move(parsed).error();
        }
        if (endpoint_->on_send) {
            return endpoint_->on_send(parsed.value(), *endpoint_);
        }
        return {};
    }

    cmux::Result<std::string> receive(cmux::Timeout) override {
        if (endpoint_->closed) {
            return cmux::make_error(cmux::ErrorCode::closed, "fake transport closed");
        }
        if (endpoint_->incoming.empty()) {
            return endpoint_->empty_error;
        }
        std::string result = std::move(endpoint_->incoming.front());
        endpoint_->incoming.pop_front();
        return result;
    }

    void close() noexcept override {
        endpoint_->closed = true;
    }

private:
    std::shared_ptr<FakeEndpoint> endpoint_;
};

cmux::TransportFactory queued_factory(
    std::vector<std::shared_ptr<FakeEndpoint>> endpoints) {
    auto queue =
        std::make_shared<std::deque<std::shared_ptr<FakeEndpoint>>>(
            endpoints.begin(), endpoints.end());
    return [queue]() -> cmux::Result<std::unique_ptr<cmux::Transport>> {
        if (queue->empty()) {
            return cmux::make_error(
                cmux::ErrorCode::connection,
                "fake transport factory exhausted");
        }
        auto endpoint = std::move(queue->front());
        queue->pop_front();
        return std::unique_ptr<cmux::Transport>(
            new FakeTransport(std::move(endpoint)));
    };
}

struct Cycle {
    std::shared_ptr<FakeEndpoint> control;
    std::shared_ptr<FakeEndpoint> stream;
};

Cycle make_cycle(
    std::uint64_t control_id,
    std::uint64_t stream_id,
    cmux::Id surface,
    std::uint16_t columns,
    std::uint16_t rows,
    std::vector<std::string> before_ack,
    std::vector<std::string> after_ack,
    cmux::Error stream_empty_error =
        cmux::make_error(cmux::ErrorCode::timeout, "script exhausted")) {
    auto control = std::make_shared<FakeEndpoint>();
    auto list_clients_count = std::make_shared<std::size_t>(0);
    control->on_send = [
        control_id,
        stream_id,
        surface,
        columns,
        rows,
        list_clients_count](const cmux::Json& message, FakeEndpoint& endpoint)
        -> cmux::Result<void> {
        auto command = cmux::require_string(message, "cmd");
        auto id = cmux::require_uint64(message, "id");
        if (!command) {
            return std::move(command).error();
        }
        if (!id) {
            return std::move(id).error();
        }

        if (command.value() == "identify") {
            endpoint.incoming.push_back(
                success_response(id.value(), identify_result()));
            return {};
        }
        if (command.value() == "list-workspaces") {
            endpoint.incoming.push_back(
                success_response(id.value(), topology(surface)));
            return {};
        }
        if (command.value() == "list-clients") {
            cmux::ListClientsResult result;
            result.value.push_back(control_client(control_id));
            if ((*list_clients_count)++ > 0) {
                result.value.push_back(
                    render_client(stream_id, surface, columns, rows));
            }
            endpoint.incoming.push_back(success_response(id.value(), result));
            return {};
        }
        if (command.value() == "set-client-sizing") {
            endpoint.incoming.push_back(
                success_response(id.value(), cmux::EmptyResult{}));
            return {};
        }
        return cmux::make_error(
            cmux::ErrorCode::protocol,
            "unexpected fake control command: " + command.value());
    };

    auto stream = std::make_shared<FakeEndpoint>();
    stream->empty_error = std::move(stream_empty_error);
    stream->on_send = [
        before_ack = std::move(before_ack),
        after_ack = std::move(after_ack)](
        const cmux::Json& message,
        FakeEndpoint& endpoint) -> cmux::Result<void> {
        auto command = cmux::require_string(message, "cmd");
        auto id = cmux::require_uint64(message, "id");
        if (!command) {
            return std::move(command).error();
        }
        if (!id) {
            return std::move(id).error();
        }
        if (command.value() != "attach-surface") {
            return cmux::make_error(
                cmux::ErrorCode::protocol,
                "unexpected fake stream command: " + command.value());
        }
        for (const auto& event : before_ack) {
            endpoint.incoming.push_back(event);
        }
        endpoint.incoming.push_back(
            success_response(id.value(), cmux::EmptyResult{}));
        for (const auto& event : after_ack) {
            endpoint.incoming.push_back(event);
        }
        return {};
    };

    return {std::move(control), std::move(stream)};
}

std::vector<std::string> sent_commands(const FakeEndpoint& endpoint) {
    std::vector<std::string> result;
    for (const auto& wire : endpoint.outgoing) {
        auto message = cmux::Json::parse(wire);
        CHECK(message);
        auto command = cmux::require_string(message.value(), "cmd");
        CHECK(command);
        result.push_back(std::move(command).value());
    }
    return result;
}

const cmux::Json& only_sent_message(const FakeEndpoint& endpoint) {
    CHECK(endpoint.outgoing.size() == 1);
    static cmux::Json parsed;
    auto result = cmux::Json::parse(endpoint.outgoing.front());
    CHECK(result);
    parsed = std::move(result).value();
    return parsed;
}

cmux_example::FrontendConfig config_for(
    std::vector<std::shared_ptr<FakeEndpoint>> controls,
    std::vector<std::shared_ptr<FakeEndpoint>> streams,
    std::uint16_t columns,
    std::uint16_t rows,
    std::size_t reconnects) {
    cmux_example::FrontendConfig config;
    config.client_options.transport_factory =
        queued_factory(std::move(controls));
    config.client_options.stream_transport_factory =
        queued_factory(std::move(streams));
    config.columns = columns;
    config.rows = rows;
    config.max_reconnects = reconnects;
    config.reconnect_delay = std::chrono::milliseconds::zero();
    config.stream_poll_timeout = std::chrono::milliseconds(1);
    return config;
}

void test_typed_render_and_detach() {
    const cmux::Id surface{7};
    cmux::ScrollChangedEvent scroll{
        .at_bottom = false,
        .offset = 9,
        .surface = surface,
    };
    cmux::DetachedEvent detached{surface};
    auto cycle = make_cycle(
        1,
        2,
        surface,
        80,
        24,
        {event_message(state_event(surface, {"old row 0", "old row 1"}))},
        {
            event_message(delta_event(surface, 1, "new row 1")),
            event_message(full_delta_event(surface, 20, {"resized"})),
            event_message(scroll),
            event_message(detached),
        });

    cmux_example::TerminalFrontend frontend(config_for(
        {cycle.control}, {cycle.stream}, 80, 24, 0));
    std::vector<std::string> frames;
    auto result = frontend.run(
        [] { return false; },
        [&](const cmux_example::ScreenBuffer& screen) {
            frames.push_back(screen.plain_text());
        });

    CHECK(result);
    CHECK(frontend.selected_surface() == surface);
    CHECK(frames.at(1) == "old row 0\nnew row 1");
    CHECK(frontend.screen().plain_text() == "resized");
    CHECK(frontend.screen().size == (cmux::Size{.cols = 20, .rows = 1}));
    CHECK(frontend.screen().scroll_offset == 9);
    CHECK(!frontend.screen().at_bottom);
    CHECK(frontend.stats().snapshots == 1);
    CHECK(frontend.stats().deltas == 2);
    CHECK(frontend.stats().scroll_updates == 1);
    CHECK(frontend.stats().detaches == 1);
    CHECK(cycle.control->closed);
    CHECK(cycle.stream->closed);

    CHECK(
        sent_commands(*cycle.control) ==
        std::vector<std::string>({
            "identify",
            "list-workspaces",
            "list-clients",
            "list-clients",
            "set-client-sizing",
        }));

    const cmux::Json& attach = only_sent_message(*cycle.stream);
    CHECK(cmux::require_string(attach, "cmd").value() == "attach-surface");
    CHECK(cmux::require_uint64(attach, "surface").value() == surface.value);
    CHECK(cmux::require_uint64(attach, "cols").value() == 80);
    CHECK(cmux::require_uint64(attach, "rows").value() == 24);
    CHECK(cmux::require_string(attach, "mode").value() == "render");

    auto sizing_wire = cmux::Json::parse(cycle.control->outgoing.back());
    CHECK(sizing_wire);
    CHECK(cmux::require_uint64(sizing_wire.value(), "surface").value() == surface.value);
    CHECK(cmux::require_uint64(sizing_wire.value(), "client").value() == 2);
    CHECK(cmux::require_bool(sizing_wire.value(), "enabled").value());
    CHECK(!cmux::require_bool(sizing_wire.value(), "exclusive").value());
}

void test_overflow_reconnects_from_fresh_snapshot() {
    const cmux::Id surface{7};
    cmux::OverflowEvent overflow;
    overflow.error = "consumer fell behind";
    overflow.surface = surface;

    auto first = make_cycle(
        10,
        11,
        surface,
        80,
        24,
        {event_message(state_event(surface, {"stale"}))},
        {event_message(overflow)});
    auto second = make_cycle(
        20,
        21,
        surface,
        80,
        24,
        {event_message(state_event(surface, {"fresh"}))},
        {event_message(cmux::DetachedEvent{surface})});

    cmux_example::TerminalFrontend frontend(config_for(
        {first.control, second.control},
        {first.stream, second.stream},
        80,
        24,
        1));
    auto result = frontend.run([] { return false; });

    CHECK(result);
    CHECK(frontend.screen().plain_text() == "fresh");
    CHECK(frontend.stats().connections == 2);
    CHECK(frontend.stats().reconnects == 1);
    CHECK(frontend.stats().snapshots == 2);
    CHECK(frontend.stats().overflows == 1);
    CHECK(first.control->closed);
    CHECK(first.stream->closed);
    CHECK(second.control->closed);
    CHECK(second.stream->closed);
}

void test_transport_failure_reconnects_from_fresh_snapshot() {
    const cmux::Id surface{7};
    auto first = make_cycle(
        30,
        31,
        surface,
        100,
        30,
        {event_message(state_event(surface, {"before failure"}))},
        {},
        cmux::make_error(cmux::ErrorCode::connection, "socket reset"));
    auto second = make_cycle(
        40,
        41,
        surface,
        100,
        30,
        {event_message(state_event(surface, {"after reconnect"}))},
        {event_message(cmux::DetachedEvent{surface})});

    cmux_example::TerminalFrontend frontend(config_for(
        {first.control, second.control},
        {first.stream, second.stream},
        100,
        30,
        1));
    auto result = frontend.run([] { return false; });

    CHECK(result);
    CHECK(frontend.screen().plain_text() == "after reconnect");
    CHECK(frontend.stats().transport_failures == 1);
    CHECK(frontend.stats().reconnects == 1);
    CHECK(frontend.stats().snapshots == 2);
}

void test_graceful_stop_closes_both_connections() {
    const cmux::Id surface{7};
    auto cycle = make_cycle(
        50,
        51,
        surface,
        80,
        24,
        {event_message(state_event(surface, {"ready"}))},
        {});

    bool stop = false;
    cmux_example::TerminalFrontend frontend(config_for(
        {cycle.control}, {cycle.stream}, 80, 24, 0));
    auto result = frontend.run(
        [&] { return stop; },
        [&](const cmux_example::ScreenBuffer&) { stop = true; });

    CHECK(result);
    CHECK(frontend.screen().plain_text() == "ready");
    CHECK(frontend.stats().detaches == 0);
    CHECK(cycle.control->closed);
    CHECK(cycle.stream->closed);
}

void run_test(std::string_view name, const std::function<void()>& test) {
    try {
        test();
        std::cout << "ok: " << name << '\n';
    } catch (const std::exception& error) {
        std::cerr << "FAILED: " << name << ": " << error.what() << '\n';
        throw;
    }
}

}  // namespace

int main() {
    try {
        run_test("typed render, scroll, sizing, and detach", test_typed_render_and_detach);
        run_test("overflow reconnect", test_overflow_reconnects_from_fresh_snapshot);
        run_test(
            "transport failure reconnect",
            test_transport_failure_reconnects_from_fresh_snapshot);
        run_test("graceful stop", test_graceful_stop_closes_both_connections);
    } catch (...) {
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
