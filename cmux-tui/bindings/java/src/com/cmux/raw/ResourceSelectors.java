// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ResourceSelectors implements WireValue {
    private final Field<String> agent;
    private final Field<String> browser;
    private final Field<String> client;
    private final Field<String> frontendProjection;
    private final Field<String> machine;
    private final Field<String> notification;
    private final Field<String> pairingRequest;
    private final Field<String> pane;
    private final Field<String> screen;
    private final Field<String> session;
    private final Field<String> sidebarView;
    private final Field<String> split;
    private final Field<String> stream;
    private final Field<String> tab;
    private final Field<String> terminal;
    private final Field<String> workspace;

    private ResourceSelectors(Builder builder) {
        this.agent = builder.agent;
        this.browser = builder.browser;
        this.client = builder.client;
        this.frontendProjection = builder.frontendProjection;
        this.machine = builder.machine;
        this.notification = builder.notification;
        this.pairingRequest = builder.pairingRequest;
        this.pane = builder.pane;
        this.screen = builder.screen;
        this.session = builder.session;
        this.sidebarView = builder.sidebarView;
        this.split = builder.split;
        this.stream = builder.stream;
        this.tab = builder.tab;
        this.terminal = builder.terminal;
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> agent() { return agent; }
    public Field<String> browser() { return browser; }
    public Field<String> client() { return client; }
    public Field<String> frontendProjection() { return frontendProjection; }
    public Field<String> machine() { return machine; }
    public Field<String> notification() { return notification; }
    public Field<String> pairingRequest() { return pairingRequest; }
    public Field<String> pane() { return pane; }
    public Field<String> screen() { return screen; }
    public Field<String> session() { return session; }
    public Field<String> sidebarView() { return sidebarView; }
    public Field<String> split() { return split; }
    public Field<String> stream() { return stream; }
    public Field<String> tab() { return tab; }
    public Field<String> terminal() { return terminal; }
    public Field<String> workspace() { return workspace; }

    public static ResourceSelectors fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ResourceSelectors");
        Builder builder = builder();
        Object rawAgent = Wire.optional(object, "agent");
        if (!Wire.isMissing(rawAgent)) {
            builder.agent(rawAgent == null ? null : Wire.string(rawAgent, "ResourceSelectors.agent"));
        }
        Object rawBrowser = Wire.optional(object, "browser");
        if (!Wire.isMissing(rawBrowser)) {
            builder.browser(rawBrowser == null ? null : Wire.string(rawBrowser, "ResourceSelectors.browser"));
        }
        Object rawClient = Wire.optional(object, "client");
        if (!Wire.isMissing(rawClient)) {
            builder.client(rawClient == null ? null : Wire.string(rawClient, "ResourceSelectors.client"));
        }
        Object rawFrontendProjection = Wire.optional(object, "frontend_projection");
        if (!Wire.isMissing(rawFrontendProjection)) {
            builder.frontendProjection(rawFrontendProjection == null ? null : Wire.string(rawFrontendProjection, "ResourceSelectors.frontend_projection"));
        }
        Object rawMachine = Wire.optional(object, "machine");
        if (!Wire.isMissing(rawMachine)) {
            builder.machine(rawMachine == null ? null : Wire.string(rawMachine, "ResourceSelectors.machine"));
        }
        Object rawNotification = Wire.optional(object, "notification");
        if (!Wire.isMissing(rawNotification)) {
            builder.notification(rawNotification == null ? null : Wire.string(rawNotification, "ResourceSelectors.notification"));
        }
        Object rawPairingRequest = Wire.optional(object, "pairing_request");
        if (!Wire.isMissing(rawPairingRequest)) {
            builder.pairingRequest(rawPairingRequest == null ? null : Wire.string(rawPairingRequest, "ResourceSelectors.pairing_request"));
        }
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(rawPane == null ? null : Wire.string(rawPane, "ResourceSelectors.pane"));
        }
        Object rawScreen = Wire.optional(object, "screen");
        if (!Wire.isMissing(rawScreen)) {
            builder.screen(rawScreen == null ? null : Wire.string(rawScreen, "ResourceSelectors.screen"));
        }
        Object rawSession = Wire.optional(object, "session");
        if (!Wire.isMissing(rawSession)) {
            builder.session(rawSession == null ? null : Wire.string(rawSession, "ResourceSelectors.session"));
        }
        Object rawSidebarView = Wire.optional(object, "sidebar_view");
        if (!Wire.isMissing(rawSidebarView)) {
            builder.sidebarView(rawSidebarView == null ? null : Wire.string(rawSidebarView, "ResourceSelectors.sidebar_view"));
        }
        Object rawSplit = Wire.optional(object, "split");
        if (!Wire.isMissing(rawSplit)) {
            builder.split(rawSplit == null ? null : Wire.string(rawSplit, "ResourceSelectors.split"));
        }
        Object rawStream = Wire.optional(object, "stream");
        if (!Wire.isMissing(rawStream)) {
            builder.stream(rawStream == null ? null : Wire.string(rawStream, "ResourceSelectors.stream"));
        }
        Object rawTab = Wire.optional(object, "tab");
        if (!Wire.isMissing(rawTab)) {
            builder.tab(rawTab == null ? null : Wire.string(rawTab, "ResourceSelectors.tab"));
        }
        Object rawTerminal = Wire.optional(object, "terminal");
        if (!Wire.isMissing(rawTerminal)) {
            builder.terminal(rawTerminal == null ? null : Wire.string(rawTerminal, "ResourceSelectors.terminal"));
        }
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(rawWorkspace == null ? null : Wire.string(rawWorkspace, "ResourceSelectors.workspace"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "agent", agent);
        Wire.put(object, "browser", browser);
        Wire.put(object, "client", client);
        Wire.put(object, "frontend_projection", frontendProjection);
        Wire.put(object, "machine", machine);
        Wire.put(object, "notification", notification);
        Wire.put(object, "pairing_request", pairingRequest);
        Wire.put(object, "pane", pane);
        Wire.put(object, "screen", screen);
        Wire.put(object, "session", session);
        Wire.put(object, "sidebar_view", sidebarView);
        Wire.put(object, "split", split);
        Wire.put(object, "stream", stream);
        Wire.put(object, "tab", tab);
        Wire.put(object, "terminal", terminal);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ResourceSelectors that)) return false;
        return Objects.equals(agent, that.agent) && Objects.equals(browser, that.browser) && Objects.equals(client, that.client) && Objects.equals(frontendProjection, that.frontendProjection) && Objects.equals(machine, that.machine) && Objects.equals(notification, that.notification) && Objects.equals(pairingRequest, that.pairingRequest) && Objects.equals(pane, that.pane) && Objects.equals(screen, that.screen) && Objects.equals(session, that.session) && Objects.equals(sidebarView, that.sidebarView) && Objects.equals(split, that.split) && Objects.equals(stream, that.stream) && Objects.equals(tab, that.tab) && Objects.equals(terminal, that.terminal) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(agent, browser, client, frontendProjection, machine, notification, pairingRequest, pane, screen, session, sidebarView, split, stream, tab, terminal, workspace); }

    @Override
    public String toString() { return "ResourceSelectors" + toWire(); }

    public static final class Builder {
        private Field<String> agent = Field.omitted();
        private Field<String> browser = Field.omitted();
        private Field<String> client = Field.omitted();
        private Field<String> frontendProjection = Field.omitted();
        private Field<String> machine = Field.omitted();
        private Field<String> notification = Field.omitted();
        private Field<String> pairingRequest = Field.omitted();
        private Field<String> pane = Field.omitted();
        private Field<String> screen = Field.omitted();
        private Field<String> session = Field.omitted();
        private Field<String> sidebarView = Field.omitted();
        private Field<String> split = Field.omitted();
        private Field<String> stream = Field.omitted();
        private Field<String> tab = Field.omitted();
        private Field<String> terminal = Field.omitted();
        private Field<String> workspace = Field.omitted();

        public Builder agent(String value) {
            this.agent = Field.ofNullable(value);
            return this;
        }
        public Builder browser(String value) {
            this.browser = Field.ofNullable(value);
            return this;
        }
        public Builder client(String value) {
            this.client = Field.ofNullable(value);
            return this;
        }
        public Builder frontendProjection(String value) {
            this.frontendProjection = Field.ofNullable(value);
            return this;
        }
        public Builder machine(String value) {
            this.machine = Field.ofNullable(value);
            return this;
        }
        public Builder notification(String value) {
            this.notification = Field.ofNullable(value);
            return this;
        }
        public Builder pairingRequest(String value) {
            this.pairingRequest = Field.ofNullable(value);
            return this;
        }
        public Builder pane(String value) {
            this.pane = Field.ofNullable(value);
            return this;
        }
        public Builder screen(String value) {
            this.screen = Field.ofNullable(value);
            return this;
        }
        public Builder session(String value) {
            this.session = Field.ofNullable(value);
            return this;
        }
        public Builder sidebarView(String value) {
            this.sidebarView = Field.ofNullable(value);
            return this;
        }
        public Builder split(String value) {
            this.split = Field.ofNullable(value);
            return this;
        }
        public Builder stream(String value) {
            this.stream = Field.ofNullable(value);
            return this;
        }
        public Builder tab(String value) {
            this.tab = Field.ofNullable(value);
            return this;
        }
        public Builder terminal(String value) {
            this.terminal = Field.ofNullable(value);
            return this;
        }
        public Builder workspace(String value) {
            this.workspace = Field.ofNullable(value);
            return this;
        }
        public ResourceSelectors build() { return new ResourceSelectors(this); }
    }
}
