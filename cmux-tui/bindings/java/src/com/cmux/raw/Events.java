// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;


public final class Events {
    private Events() {}

    public static final EventMetadata AGENT_CHANGED = new EventMetadata("agent-changed", 11, null, List.of("subscribe"), true);
    public static final EventMetadata BELL = new EventMetadata("bell", 5, null, List.of("subscribe"), true);
    public static final EventMetadata BROWSER_STATE = new EventMetadata("browser-state", 6, null, List.of("attach-browser"), true);
    public static final EventMetadata CLIENT_ATTACHED = new EventMetadata("client-attached", 6, null, List.of("subscribe"), true);
    public static final EventMetadata CLIENT_CHANGED = new EventMetadata("client-changed", 6, null, List.of("subscribe"), true);
    public static final EventMetadata CLIENT_DETACHED = new EventMetadata("client-detached", 6, null, List.of("subscribe"), true);
    public static final EventMetadata CLIENT_LIST_INVALIDATED = new EventMetadata("client-list-invalidated", 9, null, List.of("subscribe"), false);
    public static final EventMetadata COLORS_CHANGED = new EventMetadata("colors-changed", 6, null, List.of("attach-byte"), true);
    public static final EventMetadata CONFIG_RELOAD_REQUESTED = new EventMetadata("config-reload-requested", 6, null, List.of("subscribe"), true);
    public static final EventMetadata DETACHED = new EventMetadata("detached", 5, null, List.of("attach-byte", "attach-render", "attach-browser"), true);
    public static final EventMetadata EMPTY = new EventMetadata("empty", 5, null, List.of("subscribe"), true);
    public static final EventMetadata FRAME = new EventMetadata("frame", 6, null, List.of("attach-browser"), true);
    public static final EventMetadata FRONTEND_PROJECTION_CHANGED = new EventMetadata("frontend-projection-changed", 7, null, List.of("subscribe"), true);
    public static final EventMetadata GRAPHICS_STATUS = new EventMetadata("graphics-status", 10, null, List.of("subscribe"), true);
    public static final EventMetadata LAYOUT_CHANGED = new EventMetadata("layout-changed", 6, null, List.of("subscribe"), true);
    public static final EventMetadata MACHINE_USAGE_CHANGED = new EventMetadata("machine-usage-changed", 12, "machine-usage-v1", List.of("subscribe"), true);
    public static final EventMetadata NOTIFICATION = new EventMetadata("notification", 6, null, List.of("subscribe", "attach-byte", "attach-browser"), true);
    public static final EventMetadata OUTPUT = new EventMetadata("output", 5, null, List.of("attach-byte"), true);
    public static final EventMetadata OVERFLOW = new EventMetadata("overflow", 7, null, List.of("subscribe", "attach-byte", "attach-render", "attach-browser"), true);
    public static final EventMetadata PAIRING_REQUESTED = new EventMetadata("pairing-requested", 7, null, List.of("subscribe"), true);
    public static final EventMetadata PAIRING_RESOLVED = new EventMetadata("pairing-resolved", 7, null, List.of("subscribe"), true);
    public static final EventMetadata PANE_ADDED = new EventMetadata("pane-added", 7, null, List.of("subscribe-deltas"), true);
    public static final EventMetadata PANE_CLOSED = new EventMetadata("pane-closed", 7, null, List.of("subscribe-deltas"), true);
    public static final EventMetadata RENDER_DELTA = new EventMetadata("render-delta", 7, null, List.of("attach-render"), true);
    public static final EventMetadata RENDER_STATE = new EventMetadata("render-state", 7, null, List.of("attach-render"), true);
    public static final EventMetadata RESIZED = new EventMetadata("resized", 6, null, List.of("attach-byte"), true);
    public static final EventMetadata SCREEN_ADDED = new EventMetadata("screen-added", 7, null, List.of("subscribe-deltas"), true);
    public static final EventMetadata SCREEN_CLOSED = new EventMetadata("screen-closed", 7, null, List.of("subscribe-deltas"), true);
    public static final EventMetadata SCREEN_RENAMED = new EventMetadata("screen-renamed", 7, null, List.of("subscribe-deltas"), true);
    public static final EventMetadata SCROLL_CHANGED = new EventMetadata("scroll-changed", 6, null, List.of("subscribe", "attach-byte", "attach-render", "attach-browser"), true);
    public static final EventMetadata STATUS = new EventMetadata("status", 5, null, List.of("subscribe"), true);
    public static final EventMetadata SURFACE_EXITED = new EventMetadata("surface-exited", 5, null, List.of("subscribe"), true);
    public static final EventMetadata SURFACE_OUTPUT = new EventMetadata("surface-output", 5, null, List.of("subscribe"), true);
    public static final EventMetadata SURFACE_RESIZE_FAILED = new EventMetadata("surface-resize-failed", 7, null, List.of("subscribe"), true);
    public static final EventMetadata SURFACE_RESIZED = new EventMetadata("surface-resized", 5, null, List.of("subscribe"), true);
    public static final EventMetadata TAB_ADDED = new EventMetadata("tab-added", 7, null, List.of("subscribe-deltas"), true);
    public static final EventMetadata TAB_CLOSED = new EventMetadata("tab-closed", 7, null, List.of("subscribe-deltas"), true);
    public static final EventMetadata TAB_RENAMED = new EventMetadata("tab-renamed", 7, null, List.of("subscribe-deltas"), true);
    public static final EventMetadata TERMINAL_REGISTRY_CHANGED = new EventMetadata("terminal-registry-changed", 9, null, List.of("subscribe"), true);
    public static final EventMetadata TITLE_CHANGED = new EventMetadata("title-changed", 5, null, List.of("subscribe"), true);
    public static final EventMetadata TREE_CHANGED = new EventMetadata("tree-changed", 5, null, List.of("subscribe"), true);
    public static final EventMetadata VT_STATE = new EventMetadata("vt-state", 5, null, List.of("attach-byte"), true);
    public static final EventMetadata WINDOW_TITLE_REQUESTED = new EventMetadata("window-title-requested", 6, null, List.of("subscribe"), true);
    public static final EventMetadata WORKSPACE_ADDED = new EventMetadata("workspace-added", 7, null, List.of("subscribe-deltas"), true);
    public static final EventMetadata WORKSPACE_CLOSED = new EventMetadata("workspace-closed", 7, null, List.of("subscribe-deltas"), true);
    public static final EventMetadata WORKSPACE_MOVED = new EventMetadata("workspace-moved", 7, null, List.of("subscribe-deltas"), true);
    public static final EventMetadata WORKSPACE_RENAMED = new EventMetadata("workspace-renamed", 7, null, List.of("subscribe-deltas"), true);

    public static final Map<String, EventMetadata> ALL;
    static {
        LinkedHashMap<String, EventMetadata> values = new LinkedHashMap<>();
        values.put("agent-changed", AGENT_CHANGED);
        values.put("bell", BELL);
        values.put("browser-state", BROWSER_STATE);
        values.put("client-attached", CLIENT_ATTACHED);
        values.put("client-changed", CLIENT_CHANGED);
        values.put("client-detached", CLIENT_DETACHED);
        values.put("client-list-invalidated", CLIENT_LIST_INVALIDATED);
        values.put("colors-changed", COLORS_CHANGED);
        values.put("config-reload-requested", CONFIG_RELOAD_REQUESTED);
        values.put("detached", DETACHED);
        values.put("empty", EMPTY);
        values.put("frame", FRAME);
        values.put("frontend-projection-changed", FRONTEND_PROJECTION_CHANGED);
        values.put("graphics-status", GRAPHICS_STATUS);
        values.put("layout-changed", LAYOUT_CHANGED);
        values.put("machine-usage-changed", MACHINE_USAGE_CHANGED);
        values.put("notification", NOTIFICATION);
        values.put("output", OUTPUT);
        values.put("overflow", OVERFLOW);
        values.put("pairing-requested", PAIRING_REQUESTED);
        values.put("pairing-resolved", PAIRING_RESOLVED);
        values.put("pane-added", PANE_ADDED);
        values.put("pane-closed", PANE_CLOSED);
        values.put("render-delta", RENDER_DELTA);
        values.put("render-state", RENDER_STATE);
        values.put("resized", RESIZED);
        values.put("screen-added", SCREEN_ADDED);
        values.put("screen-closed", SCREEN_CLOSED);
        values.put("screen-renamed", SCREEN_RENAMED);
        values.put("scroll-changed", SCROLL_CHANGED);
        values.put("status", STATUS);
        values.put("surface-exited", SURFACE_EXITED);
        values.put("surface-output", SURFACE_OUTPUT);
        values.put("surface-resize-failed", SURFACE_RESIZE_FAILED);
        values.put("surface-resized", SURFACE_RESIZED);
        values.put("tab-added", TAB_ADDED);
        values.put("tab-closed", TAB_CLOSED);
        values.put("tab-renamed", TAB_RENAMED);
        values.put("terminal-registry-changed", TERMINAL_REGISTRY_CHANGED);
        values.put("title-changed", TITLE_CHANGED);
        values.put("tree-changed", TREE_CHANGED);
        values.put("vt-state", VT_STATE);
        values.put("window-title-requested", WINDOW_TITLE_REQUESTED);
        values.put("workspace-added", WORKSPACE_ADDED);
        values.put("workspace-closed", WORKSPACE_CLOSED);
        values.put("workspace-moved", WORKSPACE_MOVED);
        values.put("workspace-renamed", WORKSPACE_RENAMED);
        ALL = Collections.unmodifiableMap(values);
    }
}
