package com.cmux;

public enum TopologyOperation {
    WORKSPACE_CREATED("workspace-created"), SCREEN_CREATED("screen-created"),
    PANE_SPLIT("pane-split"), SURFACE_ATTACHED("surface-attached"),
    SURFACE_CLOSED("surface-closed"), PANE_CLOSED("pane-closed"),
    SCREEN_CLOSED("screen-closed"), WORKSPACE_CLOSED("workspace-closed"),
    WORKSPACE_RENAMED("workspace-renamed"), SCREEN_RENAMED("screen-renamed"),
    PANE_RENAMED("pane-renamed"), SURFACE_RENAMED("surface-renamed"),
    SPLIT_RATIO_CHANGED("split-ratio-changed"), PANES_SWAPPED("panes-swapped"),
    LAYOUT_APPLIED("layout-applied"), TAB_MOVED("tab-moved"),
    WORKSPACE_MOVED("workspace-moved");

    private final String wire;
    TopologyOperation(String wire) { this.wire = wire; }
    public String wire() { return wire; }

    static TopologyOperation from(String wire) {
        for (TopologyOperation value : values()) if (value.wire.equals(wire)) return value;
        throw new IllegalArgumentException("invalid topology operation " + wire);
    }
}
