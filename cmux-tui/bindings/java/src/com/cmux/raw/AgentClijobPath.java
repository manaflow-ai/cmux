// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentClijobPath implements WireValue {
    private final String paneId;
    private final String screenId;
    private final String tabId;
    private final String terminalId;
    private final String workspaceId;

    private AgentClijobPath(Builder builder) {
        if (!builder.paneIdSet) throw new IllegalArgumentException("pane_id is required");
        this.paneId = Wire.nonNull(builder.paneId, "pane_id");
        if (!builder.screenIdSet) throw new IllegalArgumentException("screen_id is required");
        this.screenId = Wire.nonNull(builder.screenId, "screen_id");
        if (!builder.tabIdSet) throw new IllegalArgumentException("tab_id is required");
        this.tabId = Wire.nonNull(builder.tabId, "tab_id");
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
        if (!builder.workspaceIdSet) throw new IllegalArgumentException("workspace_id is required");
        this.workspaceId = Wire.nonNull(builder.workspaceId, "workspace_id");
    }

    public static Builder builder() { return new Builder(); }

    public String kind() { return "terminal"; }
    public String paneId() { return paneId; }
    public String screenId() { return screenId; }
    public String tabId() { return tabId; }
    public String terminalId() { return terminalId; }
    public String workspaceId() { return workspaceId; }

    public static AgentClijobPath fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentClijobPath");
        Builder builder = builder();
        Object rawKind = Wire.required(object, "kind");
        ProtocolSupport.literal(rawKind, "terminal", "AgentClijobPath.kind");
        Object rawPaneId = Wire.required(object, "pane_id");
        builder.paneId(Wire.string(rawPaneId, "AgentClijobPath.pane_id"));
        Object rawScreenId = Wire.required(object, "screen_id");
        builder.screenId(Wire.string(rawScreenId, "AgentClijobPath.screen_id"));
        Object rawTabId = Wire.required(object, "tab_id");
        builder.tabId(Wire.string(rawTabId, "AgentClijobPath.tab_id"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "AgentClijobPath.terminal_id"));
        Object rawWorkspaceId = Wire.required(object, "workspace_id");
        builder.workspaceId(Wire.string(rawWorkspaceId, "AgentClijobPath.workspace_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "kind", "terminal");
        Wire.put(object, "pane_id", paneId);
        Wire.put(object, "screen_id", screenId);
        Wire.put(object, "tab_id", tabId);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "workspace_id", workspaceId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentClijobPath that)) return false;
        return Objects.equals(paneId, that.paneId) && Objects.equals(screenId, that.screenId) && Objects.equals(tabId, that.tabId) && Objects.equals(terminalId, that.terminalId) && Objects.equals(workspaceId, that.workspaceId);
    }

    @Override
    public int hashCode() { return Objects.hash(paneId, screenId, tabId, terminalId, workspaceId); }

    @Override
    public String toString() { return "AgentClijobPath" + toWire(); }

    public static final class Builder {
        private String paneId;
        private boolean paneIdSet;
        private String screenId;
        private boolean screenIdSet;
        private String tabId;
        private boolean tabIdSet;
        private String terminalId;
        private boolean terminalIdSet;
        private String workspaceId;
        private boolean workspaceIdSet;

        public Builder paneId(String value) {
            this.paneId = value;
            this.paneIdSet = true;
            return this;
        }
        public Builder screenId(String value) {
            this.screenId = value;
            this.screenIdSet = true;
            return this;
        }
        public Builder tabId(String value) {
            this.tabId = value;
            this.tabIdSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public Builder workspaceId(String value) {
            this.workspaceId = value;
            this.workspaceIdSet = true;
            return this;
        }
        public AgentClijobPath build() { return new AgentClijobPath(this); }
    }
}
