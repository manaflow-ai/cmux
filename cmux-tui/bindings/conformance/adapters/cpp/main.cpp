// Protocol-10 conformance adapter for the public C++ SDK.

#include <cmux/client.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace std::chrono_literals;

cmux::Error error(cmux::ErrorCode code, std::string message) {
    return cmux::make_error(code, std::move(message));
}

const cmux::Json* field(const cmux::Json& object, std::string_view name) {
    return object.find(name);
}

std::string string_field(
    const cmux::Json& object,
    std::string_view name,
    std::string fallback = {}) {
    const auto* value = field(object, name);
    if (value == nullptr) return fallback;
    auto text = value->as_string();
    return text ? std::string(text.value()) : fallback;
}

std::uint64_t uint_field(
    const cmux::Json& object,
    std::string_view name,
    std::uint64_t fallback) {
    const auto* value = field(object, name);
    if (value == nullptr) return fallback;
    auto number = value->as_uint64();
    return number ? number.value() : fallback;
}

cmux::ClientOptions options(const cmux::Json& request) {
    cmux::ClientOptions result;
    result.socket_path = string_field(request, "socket_path");
    result.timeout = std::chrono::milliseconds(uint_field(request, "timeout_ms", 1000));
    const auto max_frame = static_cast<std::size_t>(
        uint_field(request, "max_frame_bytes", 16U * 1024U * 1024U));
    result.transport_limits.max_message_bytes = max_frame;
    result.json_limits.max_input_bytes = max_frame;
    result.max_buffered_stream_events =
        static_cast<std::size_t>(uint_field(request, "max_buffered_events", 256));
    return result;
}

cmux::Json metadata() {
    cmux::Json::Array commands;
    for (const auto& item : cmux::command_metadata()) {
        commands.emplace_back(cmux::Json::Object{
            {"name", std::string(item.name)},
            {"authority", std::string(item.authority)},
            {"stream", std::string(item.stream_kind)},
        });
    }
    cmux::Json::Array events;
    for (const auto& item : cmux::event_metadata()) {
        cmux::Json::Array streams;
        std::string text(item.streams);
        std::size_t start = 0;
        while (start <= text.size()) {
            const auto comma = text.find(',', start);
            const auto end = comma == std::string::npos ? text.size() : comma;
            if (end > start) streams.emplace_back(text.substr(start, end - start));
            if (comma == std::string::npos) break;
            start = comma + 1;
        }
        events.emplace_back(cmux::Json::Object{
            {"name", std::string(item.name)},
            {"streams", std::move(streams)},
        });
    }
    return cmux::Json::Object{
        {"commands", std::move(commands)},
        {"events", std::move(events)},
    };
}

cmux::Result<cmux::Json> identify(const cmux::Json& request) {
    auto connected = cmux::Client::connect(options(request));
    if (!connected) return std::move(connected).error();
    auto client = std::move(connected).value();
    auto identified = client.identify();
    if (!identified) return std::move(identified).error();
    const auto& value = identified.value();
    return cmux::Json(cmux::Json::Object{
        {"app", "cmux-tui"},
        {"protocol", value.protocol},
        {"workspace_revision", std::to_string(value.workspace_revision)},
        {"terminal_revision", std::to_string(value.terminal_revision)},
    });
}

cmux::Result<cmux::Json> nullable_literal(const cmux::Json& request) {
    auto connected = cmux::Client::connect(options(request));
    if (!connected) return std::move(connected).error();
    auto client = std::move(connected).value();
    cmux::CreateTerminalRequest create;
    create.key = std::string("workspace-key");
    auto placement = client.create_terminal(create);
    if (!placement) return std::move(placement).error();
    cmux::Json lifecycle;
    if (placement.value().lifecycle) {
        lifecycle = *placement.value().lifecycle;
    }
    return cmux::Json(cmux::Json::Object{
        {"lifecycle", std::move(lifecycle)},
    });
}

cmux::Result<cmux::EventStream> open_stream(
    cmux::Client& client,
    const cmux::Json& request) {
    const auto kind = string_field(request, "stream");
    const auto surface = uint_field(request, "surface", 7);
    if (kind == "subscribe-coarse") return client.subscribe();
    if (kind == "subscribe-deltas") return client.subscribe_deltas();
    cmux::AttachSurfaceRequest attach;
    attach.surface = cmux::Id{surface};
    attach.mode = kind == "attach-render"
        ? cmux::AttachSurfaceRequestMode::render
        : cmux::AttachSurfaceRequestMode::bytes;
    if (kind == "attach-byte") return client.attach_bytes(attach);
    if (kind == "attach-render") return client.attach_render(attach);
    if (kind == "attach-browser") return client.attach_browser(attach);
    return error(cmux::ErrorCode::invalid_argument, "unknown stream " + kind);
}

bool uint64_key(std::string_view key) {
    return key == "client" || key == "index" || key == "offset" || key == "pane"
        || key == "pane_revision" || key == "projection_revision" || key == "request"
        || key == "screen" || key == "seq" || key == "surface"
        || key == "terminal_revision" || key == "timeout_ms" || key == "workspace"
        || key == "workspace_revision"
        || (key.size() >= 9 && key.substr(key.size() - 9) == "_revision");
}

cmux::Json normalize(cmux::Json value, std::string_view key = {}) {
    if (value.is_object()) {
        auto fields = value.as_object();
        if (!fields) return value;
        for (auto& [name, item] : *fields.value()) {
            item = normalize(std::move(item), name);
        }
        return value;
    }
    if (value.is_array()) {
        auto items = value.as_array();
        if (!items) return value;
        for (auto& item : *items.value()) item = normalize(std::move(item));
        return value;
    }
    if (uint64_key(key) && value.is_integer()) {
        auto number = value.as_uint64();
        if (number) return std::to_string(number.value());
    }
    return value;
}

cmux::Json event_value(cmux::Event event) {
    if (const auto* unknown = std::get_if<cmux::UnknownEvent>(&event.value)) {
        return cmux::Json::Object{
            {"event", unknown->name},
            {"unknown", true},
            {"raw", normalize(unknown->raw)},
        };
    }
    return normalize(std::move(event.raw));
}

cmux::Result<cmux::Json> run_stream(const cmux::Json& request) {
    auto connected = cmux::Client::connect(options(request));
    if (!connected) return std::move(connected).error();
    auto client = std::move(connected).value();
    auto opened = open_stream(client, request);
    if (!opened) return std::move(opened).error();
    auto stream = std::move(opened).value();
    cmux::Json::Array events;
    bool terminal = false;
    const auto count = static_cast<std::size_t>(uint_field(request, "events", 1));
    const auto timeout = std::chrono::milliseconds(uint_field(request, "timeout_ms", 1000));
    for (std::size_t index = 0; index < std::max<std::size_t>(count, 1); ++index) {
        auto received = stream.next(timeout);
        if (!received) {
            if (terminal || received.error().code == cmux::ErrorCode::closed) {
                terminal = true;
                break;
            }
            return std::move(received).error();
        }
        auto event = std::move(received).value();
        terminal = event.name() == "overflow" || event.name() == "detached";
        events.emplace_back(event_value(std::move(event)));
    }
    return cmux::Json(cmux::Json::Object{
        {"events", std::move(events)},
        {"terminal", terminal},
    });
}

cmux::Result<cmux::Json> close_pending_stream(const cmux::Json& request) {
    auto connected = cmux::Client::connect(options(request));
    if (!connected) return std::move(connected).error();
    auto client = std::move(connected).value();
    auto opened = open_stream(client, request);
    if (!opened) return std::move(opened).error();
    auto stream = std::make_shared<cmux::EventStream>(std::move(opened).value());
    std::atomic<bool> finished{false};
    std::thread reader([stream, &finished] {
        (void)stream->next(10s);
        finished.store(true, std::memory_order_release);
    });
    std::this_thread::sleep_for(
        std::chrono::milliseconds(uint_field(request, "close_after_ms", 50)));
    stream->close();
    const auto deadline = std::chrono::steady_clock::now()
        + std::chrono::milliseconds(uint_field(request, "deadline_ms", 1000));
    while (!finished.load(std::memory_order_acquire)
           && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(1ms);
    }
    const bool unblocked = finished.load(std::memory_order_acquire);
    if (unblocked) reader.join();
    else reader.detach();
    return cmux::Json(cmux::Json::Object{{"unblocked", unblocked}});
}

cmux::Result<cmux::Json> authority(const cmux::Json& request) {
    const auto authority_name = string_field(request, "authority");
    auto client_options = options(request);
    client_options.authorities.provider_authority =
        authority_name == "provider-authority";
    auto connected = cmux::Client::connect(std::move(client_options));
    if (!connected) return std::move(connected).error();
    auto client = std::move(connected).value();
    std::string command;
    if (authority_name == "control") {
        auto result = client.ping();
        if (!result) return std::move(result).error();
        command = "ping";
    } else if (authority_name == "frontend") {
        auto result = client.browser_back(cmux::BrowserBackRequest{cmux::Id{7}});
        if (!result) return std::move(result).error();
        command = "browser-back";
    } else if (authority_name == "local-admin") {
        auto result = client.pairing_response(cmux::PairingResponseRequest{false, 1});
        if (!result) return std::move(result).error();
        command = "pairing-response";
    } else if (authority_name == "provider-authority") {
        auto result = client.mark_workspaces_provider_managed(
            cmux::MarkWorkspacesProviderManagedRequest{"conformance-authority"});
        if (!result) return std::move(result).error();
        command = "mark-workspaces-provider-managed";
    } else {
        return error(cmux::ErrorCode::invalid_argument, "unknown authority " + authority_name);
    }
    return cmux::Json(cmux::Json::Object{{"command", std::move(command)}});
}

cmux::Result<cmux::Json> authority_denied(const cmux::Json& request) {
    auto connected = cmux::Client::connect(options(request));
    if (!connected) return std::move(connected).error();
    auto client = std::move(connected).value();
    auto result = client.mark_workspaces_provider_managed(
        cmux::MarkWorkspacesProviderManagedRequest{"conformance-authority"});
    if (!result && result.error().code == cmux::ErrorCode::authority) {
        return cmux::Json(cmux::Json::Object{{"denied", true}});
    }
    if (!result) return std::move(result).error();
    return error(
        cmux::ErrorCode::invalid_argument,
        "default client allowed provider-authority command");
}

struct SurfaceContext {
    cmux::Id workspace{};
    bool terminal_created = false;
};

std::optional<SurfaceContext> find_surface(
    const cmux::Tree& tree,
    cmux::Id surface) {
    for (const auto& workspace : tree.workspaces) {
        for (const auto& screen : workspace.screens) {
            for (const auto& pane : screen.panes) {
                const auto* live = std::get_if<cmux::LivePane>(&pane.value);
                if (live == nullptr) continue;
                for (const auto& tab : live->tabs) {
                    if (tab.surface == surface) {
                        return SurfaceContext{
                            workspace.id,
                            tab.kind == cmux::TabKind::pty && !tab.dead,
                        };
                    }
                }
            }
        }
    }
    return std::nullopt;
}

cmux::Result<cmux::Json> real_flow(const cmux::Json& request) {
    auto connected = cmux::Client::connect(options(request));
    if (!connected) return std::move(connected).error();
    auto client = std::move(connected).value();
    auto identity = client.identify();
    if (!identity) return std::move(identity).error();
    auto subscribed = client.subscribe_deltas();
    if (!subscribed) return std::move(subscribed).error();
    auto stream = std::move(subscribed).value();

    const auto marker = string_field(
        request, "marker", "cmux-sdk-conformance-marker");
    const auto workspace_name = string_field(
        request, "workspace_name", "sdk-conformance-workspace");
    const auto renamed_name = string_field(
        request, "renamed_name", "sdk-conformance-renamed");

    cmux::NewWorkspaceRequest create;
    create.name = workspace_name;
    create.cols = std::uint16_t{80};
    create.rows = std::uint16_t{24};
    auto created = client.new_workspace(create);
    if (!created) return std::move(created).error();
    const auto surface = created.value().surface;

    cmux::SendRequest send;
    send.surface = surface;
    send.text = "printf '" + marker + "\\n'\r";
    auto sent = client.send(send);
    if (!sent) return std::move(sent).error();

    auto waited = client.wait_for(cmux::WaitForRequest{marker, surface, 5'000});
    if (!waited) return std::move(waited).error();
    auto screen = client.read_screen(cmux::ReadScreenRequest{surface});
    if (!screen) return std::move(screen).error();
    auto tree = client.list_workspaces();
    if (!tree) return std::move(tree).error();
    const auto context = find_surface(tree.value(), surface);
    if (!context) {
        return error(
            cmux::ErrorCode::decode,
            "created surface is absent from the tree");
    }
    const auto workspace = context->workspace;

    cmux::RenameWorkspaceRequest rename;
    rename.name = renamed_name;
    rename.workspace = workspace;
    auto renamed_result = client.rename_workspace(rename);
    if (!renamed_result) return std::move(renamed_result).error();
    auto renamed_tree = client.list_workspaces();
    if (!renamed_tree) return std::move(renamed_tree).error();
    const bool renamed = std::any_of(
        renamed_tree.value().workspaces.begin(),
        renamed_tree.value().workspaces.end(),
        [&](const cmux::Workspace& item) {
            return item.id == workspace && item.name == renamed_name;
        });

    cmux::CloseWorkspaceRequest close;
    close.workspace = workspace;
    auto closed_result = client.close_workspace(close);
    if (!closed_result) return std::move(closed_result).error();
    auto remaining = client.list_workspaces();
    if (!remaining) return std::move(remaining).error();
    const bool disappeared = std::none_of(
        remaining.value().workspaces.begin(),
        remaining.value().workspaces.end(),
        [&](const cmux::Workspace& item) {
            return item.id == workspace;
        });

    const std::vector<std::string> required{
        "workspace-added",
        "workspace-renamed",
        "workspace-closed",
    };
    std::vector<std::string> observed;
    const auto timeout = std::chrono::milliseconds(
        uint_field(request, "timeout_ms", 5'000));
    while (observed.size() < 64) {
        const bool complete = std::all_of(
            required.begin(), required.end(), [&](const std::string& name) {
                return std::find(observed.begin(), observed.end(), name)
                    != observed.end();
            });
        if (complete) break;
        auto next = stream.next(timeout);
        if (!next) return std::move(next).error();
        observed.emplace_back(next.value().name());
    }
    std::ptrdiff_t previous = -1;
    bool stream_ordered = true;
    for (const auto& name : required) {
        const auto found = std::find(observed.begin(), observed.end(), name);
        const auto position = found == observed.end()
            ? std::ptrdiff_t{-1}
            : std::distance(observed.begin(), found);
        if (position <= previous) stream_ordered = false;
        previous = position;
    }
    cmux::Json::Array observed_json;
    for (const auto& name : observed) observed_json.emplace_back(name);
    return cmux::Json(cmux::Json::Object{
        {"identified", identity.value().protocol == 10},
        {"workspace_created", workspace.value > 0},
        {"terminal_created", context->terminal_created},
        {"marker_sent", true},
        {"wait_matched", true},
        {
            "read_contains_marker",
            screen.value().text.find(marker) != std::string::npos,
        },
        {"stream_ordered", stream_ordered},
        {"renamed", renamed},
        {"closed", true},
        {"disappeared", disappeared},
        {"observed_events", std::move(observed_json)},
    });
}

cmux::Result<cmux::Json> dispatch(const cmux::Json& request) {
    const auto operation = string_field(request, "op");
    if (operation == "metadata") return metadata();
    if (operation == "identify") return identify(request);
    if (operation == "nullable-literal") return nullable_literal(request);
    if (operation == "stream") return run_stream(request);
    if (operation == "close-pending-stream") return close_pending_stream(request);
    if (operation == "authority") return authority(request);
    if (operation == "authority-denied") return authority_denied(request);
    if (operation == "real-flow") return real_flow(request);
    return error(cmux::ErrorCode::invalid_argument, "unknown adapter operation " + operation);
}

std::string classify(const cmux::Error& value) {
    std::string message = value.message;
    for (auto& character : message) {
        if (character >= 'A' && character <= 'Z') character += 'a' - 'A';
    }
    if (value.code == cmux::ErrorCode::timeout) return "timeout";
    if (message.find("exceed") != std::string::npos
        || message.find("limit") != std::string::npos
        || message.find("too large") != std::string::npos) {
        return "limit";
    }
    if (value.code == cmux::ErrorCode::command) return "command";
    if (value.code == cmux::ErrorCode::decode
        || message.find("utf-8") != std::string::npos
        || message.find("json") != std::string::npos) {
        return "decode";
    }
    return "transport";
}

}  // namespace

int main() {
    std::ostringstream input;
    input << std::cin.rdbuf();
    auto parsed = cmux::Json::parse(input.str());
    if (!parsed) {
        std::cerr << parsed.error().message << '\n';
        return 2;
    }
    auto request = std::move(parsed).value();
    cmux::Json::Object response{
        {"contract_version", std::uint64_t{1}},
        {"id", request.find("id") == nullptr ? cmux::Json{} : *request.find("id")},
    };
    auto result = dispatch(request);
    if (result) {
        response.emplace("ok", true);
        response.emplace("value", std::move(result).value());
    } else {
        auto failure = std::move(result).error();
        response.emplace("ok", false);
        response.emplace(
            "error",
            cmux::Json::Object{
                {"kind", classify(failure)},
                {"message", failure.message},
            });
    }
    auto encoded = cmux::Json(std::move(response)).encode();
    if (!encoded) {
        std::cerr << encoded.error().message << '\n';
        return 2;
    }
    std::cout << encoded.value() << '\n';
}
