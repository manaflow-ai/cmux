// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.Map;


public final class Protocol {
    public static final String SDK_VERSION = "1.0.0";
    public static final int VERSION = 12;
    public static final int SCHEMA_VERSION = 2;
    public static final String IR_SHA256 = "65aa592727bc414fe3e66ac125c9b8541a1926bbe9eaa572acc66b4681bf6589";
    private Protocol() {}

    public static ProtocolEvent decodeEvent(Object value) {
        Map<String, Object> object = Wire.object(value, "event");
        String event = Wire.string(Wire.required(object, "event"), "event.event");
        return switch (event) {
            case "agent-changed" -> AgentChangedEvent.fromWire(value);
            case "bell" -> BellEvent.fromWire(value);
            case "browser-state" -> BrowserStateEvent.fromWire(value);
            case "client-attached" -> ClientAttachedEvent.fromWire(value);
            case "client-changed" -> ClientChangedEvent.fromWire(value);
            case "client-detached" -> ClientDetachedEvent.fromWire(value);
            case "client-list-invalidated" -> ClientListInvalidatedEvent.fromWire(value);
            case "colors-changed" -> ColorsChangedEvent.fromWire(value);
            case "config-reload-requested" -> ConfigReloadRequestedEvent.fromWire(value);
            case "detached" -> DetachedEvent.fromWire(value);
            case "empty" -> EmptyEvent.fromWire(value);
            case "frame" -> FrameEvent.fromWire(value);
            case "frontend-projection-changed" -> FrontendProjectionChangedEvent.fromWire(value);
            case "graphics-status" -> GraphicsStatusEvent.fromWire(value);
            case "layout-changed" -> LayoutChangedEvent.fromWire(value);
            case "notification" -> NotificationEvent.fromWire(value);
            case "output" -> OutputEvent.fromWire(value);
            case "overflow" -> OverflowEvent.fromWire(value);
            case "pairing-requested" -> PairingRequestedEvent.fromWire(value);
            case "pairing-resolved" -> PairingResolvedEvent.fromWire(value);
            case "pane-added" -> PaneAddedEvent.fromWire(value);
            case "pane-closed" -> PaneClosedEvent.fromWire(value);
            case "render-delta" -> RenderDeltaEvent.fromWire(value);
            case "render-state" -> RenderStateEvent.fromWire(value);
            case "resized" -> ResizedEvent.fromWire(value);
            case "screen-added" -> ScreenAddedEvent.fromWire(value);
            case "screen-closed" -> ScreenClosedEvent.fromWire(value);
            case "screen-renamed" -> ScreenRenamedEvent.fromWire(value);
            case "scroll-changed" -> ScrollChangedEvent.fromWire(value);
            case "status" -> StatusEvent.fromWire(value);
            case "surface-exited" -> SurfaceExitedEvent.fromWire(value);
            case "surface-output" -> SurfaceOutputEvent.fromWire(value);
            case "surface-resize-failed" -> SurfaceResizeFailedEvent.fromWire(value);
            case "surface-resized" -> SurfaceResizedEvent.fromWire(value);
            case "tab-added" -> TabAddedEvent.fromWire(value);
            case "tab-closed" -> TabClosedEvent.fromWire(value);
            case "tab-renamed" -> TabRenamedEvent.fromWire(value);
            case "terminal-registry-changed" -> TerminalRegistryChangedEvent.fromWire(value);
            case "title-changed" -> TitleChangedEvent.fromWire(value);
            case "tree-changed" -> TreeChangedEvent.fromWire(value);
            case "vt-state" -> VtStateEvent.fromWire(value);
            case "window-title-requested" -> WindowTitleRequestedEvent.fromWire(value);
            case "workspace-added" -> WorkspaceAddedEvent.fromWire(value);
            case "workspace-closed" -> WorkspaceClosedEvent.fromWire(value);
            case "workspace-moved" -> WorkspaceMovedEvent.fromWire(value);
            case "workspace-renamed" -> WorkspaceRenamedEvent.fromWire(value);
            default -> UnknownEvent.fromWire(value);
        };
    }
}
