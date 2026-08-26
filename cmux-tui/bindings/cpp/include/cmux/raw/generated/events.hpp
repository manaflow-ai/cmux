#pragma once

#include <span>
#include <string>
#include <string_view>
#include <variant>

#include "cmux/raw/generated/models.hpp"
#include "cmux/raw/stream.hpp"

namespace cmux::raw {

struct UnknownEvent {
    std::string name;
    Json raw;
    friend bool operator==(const UnknownEvent&, const UnknownEvent&) = default;
};

struct Event {
    using Variant = std::variant<AgentChangedEvent, BellEvent, BrowserStateEvent, ClientAttachedEvent, ClientChangedEvent, ClientDetachedEvent, ClientListInvalidatedEvent, ColorsChangedEvent, ConfigReloadRequestedEvent, DetachedEvent, EmptyEvent, FrameEvent, FrontendProjectionChangedEvent, GraphicsStatusEvent, LayoutChangedEvent, NotificationEvent, OutputEvent, OverflowEvent, PairingRequestedEvent, PairingResolvedEvent, PaneAddedEvent, PaneClosedEvent, RenderDeltaEvent, RenderStateEvent, ResizedEvent, ScreenAddedEvent, ScreenClosedEvent, ScreenRenamedEvent, ScrollChangedEvent, StatusEvent, SurfaceExitedEvent, SurfaceOutputEvent, SurfaceResizeFailedEvent, SurfaceResizedEvent, TabAddedEvent, TabClosedEvent, TabRenamedEvent, TerminalRegistryChangedEvent, TitleChangedEvent, TreeChangedEvent, VtStateEvent, WindowTitleRequestedEvent, WorkspaceAddedEvent, WorkspaceClosedEvent, WorkspaceMovedEvent, WorkspaceRenamedEvent, UnknownEvent>;
    Variant value;
    Json raw;
    [[nodiscard]] std::string_view name() const noexcept;
};

template <>
struct Codec<Event> {
    static Result<Json> encode(const Event& value);
    static Result<Event> decode(const Json& value);
};

using EventStream = Stream<Event>;
using SubscriptionStream = EventStream;
using DeltaStream = EventStream;
using ByteStream = EventStream;
using RenderStream = EventStream;
using BrowserStream = EventStream;

struct EventMetadata {
    std::string_view name;
    std::uint32_t since;
    std::string_view capability;
    std::string_view streams;
    std::string_view emission;
};

[[nodiscard]] std::span<const EventMetadata> event_metadata() noexcept;

}  // namespace cmux::raw
