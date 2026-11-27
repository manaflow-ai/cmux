// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class Tab implements WireValue {
    /** app-screens-v1: the app (and route) an app tab shows. */
    private final Field<Object> app;
    /** tab-attention-v1: an agent needs the person in this tab. */
    private final Field<TabAttention> attention;
    /** A frontend browser's engine. */
    private final Field<String> browserEngine;
    private final Field<String> browserError;
    private final Field<Boolean> browserFramesStalled;
    /** The frontend that owns the browser. */
    private final Field<String> browserOwner;
    /** A frontend browser's profile. */
    private final Field<String> browserProfileId;
    /** Who renders a browser tab. */
    private final Field<TabBrowserRenderer> browserRenderer;
    private final TabBrowserSource browserSource;
    private final Field<TabBrowserStatus> browserStatus;
    /** The public id of what the tab shows. */
    private final Field<String> contentResourceId;
    /** What a conversation tab shows. */
    private final Field<ConversationTabRecord> conversation;
    /** The terminal's working directory. */
    private final Field<String> cwd;
    private final boolean dead;
    /** terminal-state-v1: why a dead terminal ended. */
    private final Field<TerminalTabEnd> end;
    /** A frontend browser's favicon. */
    private final Field<String> faviconUrl;
    /** The git branch of cwd. */
    private final Field<String> gitBranch;
    /** cwd's checkout has a detached HEAD. */
    private final Field<Boolean> gitDetached;
    /** The tab group the tab is in. */
    private final Field<String> group;
    /** The record version of a terminal its host has but cannot adopt. */
    private final Field<UInt64> hostRecordVersion;
    private final TabKind kind;
    private final String name;
    private final Field<NotificationMarker> notification;
    /** The tab is pinned. */
    private final Field<Boolean> pinned;
    /** A pinned browser tab's home URL. */
    private final Field<String> pinnedUrl;
    private final Field<ShownProgramStatus> programStatus;
    /** How the tab relaunches after a restart. */
    private final Field<Object> relaunch;
    /** A remote terminal tab's record. */
    private final Field<Object> remote;
    private final Field<String> shortId;
    private final Size size;
    private final Field<Boolean> supportsClearHistoryKeyFallback;
    private final UInt64 surface;
    /** The tab's public id. */
    private final Field<String> tabResourceId;
    /** Why a terminal will end with something other than its shell although terminal hosts are on: `breakaway_denied` (Windows: the host runs inside the daemon's kill-on-close Job Object and ends when that job closes) or `host_start_failed` (no host; the daemon runs the terminal and it ends with the daemon). Null otherwise and for browser tabs. A string, not an enum: clients read an unknown value as a notice for another reason. */
    private final Field<String> terminalHostFallback;
    private final Field<String> terminalId;
    private final Field<String> terminalIncarnation;
    private final Field<String> terminalResourceId;
    /** running, reconnecting, failed or exited, for a terminal tab. */
    private final Field<String> terminalState;
    private final String title;
    private final Field<String> titleActivity;
    private final Field<String> titleText;
    /** A browser tab's URL. */
    private final Field<String> url;

    private Tab(Builder builder) {
        this.app = builder.app.map(value -> Wire.immutableJson(value));
        this.attention = builder.attention;
        this.browserEngine = builder.browserEngine;
        this.browserError = builder.browserError;
        this.browserFramesStalled = builder.browserFramesStalled;
        this.browserOwner = builder.browserOwner;
        this.browserProfileId = builder.browserProfileId;
        this.browserRenderer = builder.browserRenderer;
        if (!builder.browserSourceSet) throw new IllegalArgumentException("browser_source is required");
        this.browserSource = builder.browserSource;
        this.browserStatus = builder.browserStatus;
        this.contentResourceId = builder.contentResourceId;
        this.conversation = builder.conversation;
        this.cwd = builder.cwd;
        if (!builder.deadSet) throw new IllegalArgumentException("dead is required");
        this.dead = builder.dead;
        this.end = builder.end;
        this.faviconUrl = builder.faviconUrl;
        this.gitBranch = builder.gitBranch;
        this.gitDetached = builder.gitDetached;
        this.group = builder.group;
        this.hostRecordVersion = builder.hostRecordVersion;
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = builder.name;
        this.notification = builder.notification;
        this.pinned = builder.pinned;
        this.pinnedUrl = builder.pinnedUrl;
        this.programStatus = builder.programStatus;
        this.relaunch = builder.relaunch.map(value -> Wire.immutableJson(value));
        this.remote = builder.remote.map(value -> Wire.immutableJson(value));
        this.shortId = builder.shortId;
        if (!builder.sizeSet) throw new IllegalArgumentException("size is required");
        this.size = builder.size;
        this.supportsClearHistoryKeyFallback = builder.supportsClearHistoryKeyFallback;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.tabResourceId = builder.tabResourceId;
        this.terminalHostFallback = builder.terminalHostFallback;
        this.terminalId = builder.terminalId;
        this.terminalIncarnation = builder.terminalIncarnation;
        this.terminalResourceId = builder.terminalResourceId;
        this.terminalState = builder.terminalState;
        if (!builder.titleSet) throw new IllegalArgumentException("title is required");
        this.title = Wire.nonNull(builder.title, "title");
        this.titleActivity = builder.titleActivity;
        this.titleText = builder.titleText;
        this.url = builder.url;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Object> app() { return app; }
    public Field<TabAttention> attention() { return attention; }
    public Field<String> browserEngine() { return browserEngine; }
    public Field<String> browserError() { return browserError; }
    public Field<Boolean> browserFramesStalled() { return browserFramesStalled; }
    public Field<String> browserOwner() { return browserOwner; }
    public Field<String> browserProfileId() { return browserProfileId; }
    public Field<TabBrowserRenderer> browserRenderer() { return browserRenderer; }
    public TabBrowserSource browserSource() { return browserSource; }
    public Field<TabBrowserStatus> browserStatus() { return browserStatus; }
    public Field<String> contentResourceId() { return contentResourceId; }
    public Field<ConversationTabRecord> conversation() { return conversation; }
    public Field<String> cwd() { return cwd; }
    public boolean dead() { return dead; }
    public Field<TerminalTabEnd> end() { return end; }
    public Field<String> faviconUrl() { return faviconUrl; }
    public Field<String> gitBranch() { return gitBranch; }
    public Field<Boolean> gitDetached() { return gitDetached; }
    public Field<String> group() { return group; }
    public Field<UInt64> hostRecordVersion() { return hostRecordVersion; }
    public TabKind kind() { return kind; }
    public String name() { return name; }
    public Field<NotificationMarker> notification() { return notification; }
    public Field<Boolean> pinned() { return pinned; }
    public Field<String> pinnedUrl() { return pinnedUrl; }
    public Field<ShownProgramStatus> programStatus() { return programStatus; }
    public Field<Object> relaunch() { return relaunch; }
    public Field<Object> remote() { return remote; }
    public Field<String> shortId() { return shortId; }
    public Size size() { return size; }
    public Field<Boolean> supportsClearHistoryKeyFallback() { return supportsClearHistoryKeyFallback; }
    public UInt64 surface() { return surface; }
    public Field<String> tabResourceId() { return tabResourceId; }
    public Field<String> terminalHostFallback() { return terminalHostFallback; }
    public Field<String> terminalId() { return terminalId; }
    public Field<String> terminalIncarnation() { return terminalIncarnation; }
    public Field<String> terminalResourceId() { return terminalResourceId; }
    public Field<String> terminalState() { return terminalState; }
    public String title() { return title; }
    public Field<String> titleActivity() { return titleActivity; }
    public Field<String> titleText() { return titleText; }
    public Field<String> url() { return url; }

    public static Tab fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "Tab");
        Builder builder = builder();
        Object rawApp = Wire.optional(object, "app");
        if (!Wire.isMissing(rawApp)) {
            builder.app(Wire.immutableJson(ProtocolSupport.nonNull(rawApp, "Tab.app")));
        }
        Object rawAttention = Wire.optional(object, "attention");
        if (!Wire.isMissing(rawAttention)) {
            builder.attention(rawAttention == null ? null : TabAttention.fromWire(rawAttention));
        }
        Object rawBrowserEngine = Wire.optional(object, "browser_engine");
        if (!Wire.isMissing(rawBrowserEngine)) {
            builder.browserEngine(rawBrowserEngine == null ? null : Wire.string(rawBrowserEngine, "Tab.browser_engine"));
        }
        Object rawBrowserError = Wire.optional(object, "browser_error");
        if (!Wire.isMissing(rawBrowserError)) {
            builder.browserError(rawBrowserError == null ? null : Wire.string(rawBrowserError, "Tab.browser_error"));
        }
        Object rawBrowserFramesStalled = Wire.optional(object, "browser_frames_stalled");
        if (!Wire.isMissing(rawBrowserFramesStalled)) {
            builder.browserFramesStalled(rawBrowserFramesStalled == null ? null : Wire.bool(rawBrowserFramesStalled, "Tab.browser_frames_stalled"));
        }
        Object rawBrowserOwner = Wire.optional(object, "browser_owner");
        if (!Wire.isMissing(rawBrowserOwner)) {
            builder.browserOwner(rawBrowserOwner == null ? null : Wire.string(rawBrowserOwner, "Tab.browser_owner"));
        }
        Object rawBrowserProfileId = Wire.optional(object, "browser_profile_id");
        if (!Wire.isMissing(rawBrowserProfileId)) {
            builder.browserProfileId(rawBrowserProfileId == null ? null : Wire.string(rawBrowserProfileId, "Tab.browser_profile_id"));
        }
        Object rawBrowserRenderer = Wire.optional(object, "browser_renderer");
        if (!Wire.isMissing(rawBrowserRenderer)) {
            builder.browserRenderer(rawBrowserRenderer == null ? null : TabBrowserRenderer.fromWire(rawBrowserRenderer));
        }
        Object rawBrowserSource = Wire.required(object, "browser_source");
        builder.browserSource(rawBrowserSource == null ? null : TabBrowserSource.fromWire(rawBrowserSource));
        Object rawBrowserStatus = Wire.optional(object, "browser_status");
        if (!Wire.isMissing(rawBrowserStatus)) {
            builder.browserStatus(rawBrowserStatus == null ? null : TabBrowserStatus.fromWire(rawBrowserStatus));
        }
        Object rawContentResourceId = Wire.optional(object, "content_resource_id");
        if (!Wire.isMissing(rawContentResourceId)) {
            builder.contentResourceId(rawContentResourceId == null ? null : Wire.string(rawContentResourceId, "Tab.content_resource_id"));
        }
        Object rawConversation = Wire.optional(object, "conversation");
        if (!Wire.isMissing(rawConversation)) {
            builder.conversation(rawConversation == null ? null : ConversationTabRecord.fromWire(rawConversation));
        }
        Object rawCwd = Wire.optional(object, "cwd");
        if (!Wire.isMissing(rawCwd)) {
            builder.cwd(rawCwd == null ? null : Wire.string(rawCwd, "Tab.cwd"));
        }
        Object rawDead = Wire.required(object, "dead");
        builder.dead(Wire.bool(rawDead, "Tab.dead"));
        Object rawEnd = Wire.optional(object, "end");
        if (!Wire.isMissing(rawEnd)) {
            builder.end(rawEnd == null ? null : TerminalTabEnd.fromWire(rawEnd));
        }
        Object rawFaviconUrl = Wire.optional(object, "favicon_url");
        if (!Wire.isMissing(rawFaviconUrl)) {
            builder.faviconUrl(rawFaviconUrl == null ? null : Wire.string(rawFaviconUrl, "Tab.favicon_url"));
        }
        Object rawGitBranch = Wire.optional(object, "git_branch");
        if (!Wire.isMissing(rawGitBranch)) {
            builder.gitBranch(rawGitBranch == null ? null : Wire.string(rawGitBranch, "Tab.git_branch"));
        }
        Object rawGitDetached = Wire.optional(object, "git_detached");
        if (!Wire.isMissing(rawGitDetached)) {
            builder.gitDetached(Wire.bool(rawGitDetached, "Tab.git_detached"));
        }
        Object rawGroup = Wire.optional(object, "group");
        if (!Wire.isMissing(rawGroup)) {
            builder.group(rawGroup == null ? null : Wire.string(rawGroup, "Tab.group"));
        }
        Object rawHostRecordVersion = Wire.optional(object, "host_record_version");
        if (!Wire.isMissing(rawHostRecordVersion)) {
            builder.hostRecordVersion(rawHostRecordVersion == null ? null : Wire.uint64(rawHostRecordVersion, "Tab.host_record_version"));
        }
        Object rawKind = Wire.required(object, "kind");
        builder.kind(TabKind.fromWire(rawKind));
        Object rawName = Wire.required(object, "name");
        builder.name(rawName == null ? null : Wire.string(rawName, "Tab.name"));
        Object rawNotification = Wire.optional(object, "notification");
        if (!Wire.isMissing(rawNotification)) {
            builder.notification(rawNotification == null ? null : NotificationMarker.fromWire(rawNotification));
        }
        Object rawPinned = Wire.optional(object, "pinned");
        if (!Wire.isMissing(rawPinned)) {
            builder.pinned(Wire.bool(rawPinned, "Tab.pinned"));
        }
        Object rawPinnedUrl = Wire.optional(object, "pinned_url");
        if (!Wire.isMissing(rawPinnedUrl)) {
            builder.pinnedUrl(rawPinnedUrl == null ? null : Wire.string(rawPinnedUrl, "Tab.pinned_url"));
        }
        Object rawProgramStatus = Wire.optional(object, "program_status");
        if (!Wire.isMissing(rawProgramStatus)) {
            builder.programStatus(rawProgramStatus == null ? null : ShownProgramStatus.fromWire(rawProgramStatus));
        }
        Object rawRelaunch = Wire.optional(object, "relaunch");
        if (!Wire.isMissing(rawRelaunch)) {
            builder.relaunch(rawRelaunch == null ? null : Wire.immutableJson(rawRelaunch));
        }
        Object rawRemote = Wire.optional(object, "remote");
        if (!Wire.isMissing(rawRemote)) {
            builder.remote(Wire.immutableJson(ProtocolSupport.nonNull(rawRemote, "Tab.remote")));
        }
        Object rawShortId = Wire.optional(object, "short_id");
        if (!Wire.isMissing(rawShortId)) {
            builder.shortId(Wire.string(rawShortId, "Tab.short_id"));
        }
        Object rawSize = Wire.required(object, "size");
        builder.size(rawSize == null ? null : Size.fromWire(rawSize));
        Object rawSupportsClearHistoryKeyFallback = Wire.optional(object, "supports_clear_history_key_fallback");
        if (!Wire.isMissing(rawSupportsClearHistoryKeyFallback)) {
            builder.supportsClearHistoryKeyFallback(Wire.bool(rawSupportsClearHistoryKeyFallback, "Tab.supports_clear_history_key_fallback"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "Tab.surface"));
        Object rawTabResourceId = Wire.optional(object, "tab_resource_id");
        if (!Wire.isMissing(rawTabResourceId)) {
            builder.tabResourceId(rawTabResourceId == null ? null : Wire.string(rawTabResourceId, "Tab.tab_resource_id"));
        }
        Object rawTerminalHostFallback = Wire.optional(object, "terminal_host_fallback");
        if (!Wire.isMissing(rawTerminalHostFallback)) {
            builder.terminalHostFallback(rawTerminalHostFallback == null ? null : Wire.string(rawTerminalHostFallback, "Tab.terminal_host_fallback"));
        }
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "Tab.terminal_id"));
        }
        Object rawTerminalIncarnation = Wire.optional(object, "terminal_incarnation");
        if (!Wire.isMissing(rawTerminalIncarnation)) {
            builder.terminalIncarnation(rawTerminalIncarnation == null ? null : Wire.string(rawTerminalIncarnation, "Tab.terminal_incarnation"));
        }
        Object rawTerminalResourceId = Wire.optional(object, "terminal_resource_id");
        if (!Wire.isMissing(rawTerminalResourceId)) {
            builder.terminalResourceId(rawTerminalResourceId == null ? null : Wire.string(rawTerminalResourceId, "Tab.terminal_resource_id"));
        }
        Object rawTerminalState = Wire.optional(object, "terminal_state");
        if (!Wire.isMissing(rawTerminalState)) {
            builder.terminalState(rawTerminalState == null ? null : Wire.string(rawTerminalState, "Tab.terminal_state"));
        }
        Object rawTitle = Wire.required(object, "title");
        builder.title(Wire.string(rawTitle, "Tab.title"));
        Object rawTitleActivity = Wire.optional(object, "title_activity");
        if (!Wire.isMissing(rawTitleActivity)) {
            builder.titleActivity(rawTitleActivity == null ? null : Wire.string(rawTitleActivity, "Tab.title_activity"));
        }
        Object rawTitleText = Wire.optional(object, "title_text");
        if (!Wire.isMissing(rawTitleText)) {
            builder.titleText(Wire.string(rawTitleText, "Tab.title_text"));
        }
        Object rawUrl = Wire.optional(object, "url");
        if (!Wire.isMissing(rawUrl)) {
            builder.url(rawUrl == null ? null : Wire.string(rawUrl, "Tab.url"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "app", app);
        Wire.put(object, "attention", attention);
        Wire.put(object, "browser_engine", browserEngine);
        Wire.put(object, "browser_error", browserError);
        Wire.put(object, "browser_frames_stalled", browserFramesStalled);
        Wire.put(object, "browser_owner", browserOwner);
        Wire.put(object, "browser_profile_id", browserProfileId);
        Wire.put(object, "browser_renderer", browserRenderer);
        Wire.put(object, "browser_source", browserSource);
        Wire.put(object, "browser_status", browserStatus);
        Wire.put(object, "content_resource_id", contentResourceId);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "cwd", cwd);
        Wire.put(object, "dead", dead);
        Wire.put(object, "end", end);
        Wire.put(object, "favicon_url", faviconUrl);
        Wire.put(object, "git_branch", gitBranch);
        Wire.put(object, "git_detached", gitDetached);
        Wire.put(object, "group", group);
        Wire.put(object, "host_record_version", hostRecordVersion);
        Wire.put(object, "kind", kind);
        Wire.put(object, "name", name);
        Wire.put(object, "notification", notification);
        Wire.put(object, "pinned", pinned);
        Wire.put(object, "pinned_url", pinnedUrl);
        Wire.put(object, "program_status", programStatus);
        Wire.put(object, "relaunch", relaunch);
        Wire.put(object, "remote", remote);
        Wire.put(object, "short_id", shortId);
        Wire.put(object, "size", size);
        Wire.put(object, "supports_clear_history_key_fallback", supportsClearHistoryKeyFallback);
        Wire.put(object, "surface", surface);
        Wire.put(object, "tab_resource_id", tabResourceId);
        Wire.put(object, "terminal_host_fallback", terminalHostFallback);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "terminal_incarnation", terminalIncarnation);
        Wire.put(object, "terminal_resource_id", terminalResourceId);
        Wire.put(object, "terminal_state", terminalState);
        Wire.put(object, "title", title);
        Wire.put(object, "title_activity", titleActivity);
        Wire.put(object, "title_text", titleText);
        Wire.put(object, "url", url);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof Tab that)) return false;
        return Objects.equals(app, that.app) && Objects.equals(attention, that.attention) && Objects.equals(browserEngine, that.browserEngine) && Objects.equals(browserError, that.browserError) && Objects.equals(browserFramesStalled, that.browserFramesStalled) && Objects.equals(browserOwner, that.browserOwner) && Objects.equals(browserProfileId, that.browserProfileId) && Objects.equals(browserRenderer, that.browserRenderer) && Objects.equals(browserSource, that.browserSource) && Objects.equals(browserStatus, that.browserStatus) && Objects.equals(contentResourceId, that.contentResourceId) && Objects.equals(conversation, that.conversation) && Objects.equals(cwd, that.cwd) && Objects.equals(dead, that.dead) && Objects.equals(end, that.end) && Objects.equals(faviconUrl, that.faviconUrl) && Objects.equals(gitBranch, that.gitBranch) && Objects.equals(gitDetached, that.gitDetached) && Objects.equals(group, that.group) && Objects.equals(hostRecordVersion, that.hostRecordVersion) && Objects.equals(kind, that.kind) && Objects.equals(name, that.name) && Objects.equals(notification, that.notification) && Objects.equals(pinned, that.pinned) && Objects.equals(pinnedUrl, that.pinnedUrl) && Objects.equals(programStatus, that.programStatus) && Objects.equals(relaunch, that.relaunch) && Objects.equals(remote, that.remote) && Objects.equals(shortId, that.shortId) && Objects.equals(size, that.size) && Objects.equals(supportsClearHistoryKeyFallback, that.supportsClearHistoryKeyFallback) && Objects.equals(surface, that.surface) && Objects.equals(tabResourceId, that.tabResourceId) && Objects.equals(terminalHostFallback, that.terminalHostFallback) && Objects.equals(terminalId, that.terminalId) && Objects.equals(terminalIncarnation, that.terminalIncarnation) && Objects.equals(terminalResourceId, that.terminalResourceId) && Objects.equals(terminalState, that.terminalState) && Objects.equals(title, that.title) && Objects.equals(titleActivity, that.titleActivity) && Objects.equals(titleText, that.titleText) && Objects.equals(url, that.url);
    }

    @Override
    public int hashCode() { return Objects.hash(app, attention, browserEngine, browserError, browserFramesStalled, browserOwner, browserProfileId, browserRenderer, browserSource, browserStatus, contentResourceId, conversation, cwd, dead, end, faviconUrl, gitBranch, gitDetached, group, hostRecordVersion, kind, name, notification, pinned, pinnedUrl, programStatus, relaunch, remote, shortId, size, supportsClearHistoryKeyFallback, surface, tabResourceId, terminalHostFallback, terminalId, terminalIncarnation, terminalResourceId, terminalState, title, titleActivity, titleText, url); }

    @Override
    public String toString() { return "Tab" + toWire(); }

    public static final class Builder {
        private Field<Object> app = Field.omitted();
        private Field<TabAttention> attention = Field.omitted();
        private Field<String> browserEngine = Field.omitted();
        private Field<String> browserError = Field.omitted();
        private Field<Boolean> browserFramesStalled = Field.omitted();
        private Field<String> browserOwner = Field.omitted();
        private Field<String> browserProfileId = Field.omitted();
        private Field<TabBrowserRenderer> browserRenderer = Field.omitted();
        private TabBrowserSource browserSource;
        private boolean browserSourceSet;
        private Field<TabBrowserStatus> browserStatus = Field.omitted();
        private Field<String> contentResourceId = Field.omitted();
        private Field<ConversationTabRecord> conversation = Field.omitted();
        private Field<String> cwd = Field.omitted();
        private Boolean dead;
        private boolean deadSet;
        private Field<TerminalTabEnd> end = Field.omitted();
        private Field<String> faviconUrl = Field.omitted();
        private Field<String> gitBranch = Field.omitted();
        private Field<Boolean> gitDetached = Field.omitted();
        private Field<String> group = Field.omitted();
        private Field<UInt64> hostRecordVersion = Field.omitted();
        private TabKind kind;
        private boolean kindSet;
        private String name;
        private boolean nameSet;
        private Field<NotificationMarker> notification = Field.omitted();
        private Field<Boolean> pinned = Field.omitted();
        private Field<String> pinnedUrl = Field.omitted();
        private Field<ShownProgramStatus> programStatus = Field.omitted();
        private Field<Object> relaunch = Field.omitted();
        private Field<Object> remote = Field.omitted();
        private Field<String> shortId = Field.omitted();
        private Size size;
        private boolean sizeSet;
        private Field<Boolean> supportsClearHistoryKeyFallback = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> tabResourceId = Field.omitted();
        private Field<String> terminalHostFallback = Field.omitted();
        private Field<String> terminalId = Field.omitted();
        private Field<String> terminalIncarnation = Field.omitted();
        private Field<String> terminalResourceId = Field.omitted();
        private Field<String> terminalState = Field.omitted();
        private String title;
        private boolean titleSet;
        private Field<String> titleActivity = Field.omitted();
        private Field<String> titleText = Field.omitted();
        private Field<String> url = Field.omitted();

        public Builder app(Object value) {
            this.app = Field.of(value);
            return this;
        }
        public Builder attention(TabAttention value) {
            this.attention = Field.ofNullable(value);
            return this;
        }
        public Builder browserEngine(String value) {
            this.browserEngine = Field.ofNullable(value);
            return this;
        }
        public Builder browserError(String value) {
            this.browserError = Field.ofNullable(value);
            return this;
        }
        public Builder browserFramesStalled(Boolean value) {
            this.browserFramesStalled = Field.ofNullable(value);
            return this;
        }
        public Builder browserOwner(String value) {
            this.browserOwner = Field.ofNullable(value);
            return this;
        }
        public Builder browserProfileId(String value) {
            this.browserProfileId = Field.ofNullable(value);
            return this;
        }
        public Builder browserRenderer(TabBrowserRenderer value) {
            this.browserRenderer = Field.ofNullable(value);
            return this;
        }
        public Builder browserSource(TabBrowserSource value) {
            this.browserSource = value;
            this.browserSourceSet = true;
            return this;
        }
        public Builder browserStatus(TabBrowserStatus value) {
            this.browserStatus = Field.ofNullable(value);
            return this;
        }
        public Builder contentResourceId(String value) {
            this.contentResourceId = Field.ofNullable(value);
            return this;
        }
        public Builder conversation(ConversationTabRecord value) {
            this.conversation = Field.ofNullable(value);
            return this;
        }
        public Builder cwd(String value) {
            this.cwd = Field.ofNullable(value);
            return this;
        }
        public Builder dead(boolean value) {
            this.dead = value;
            this.deadSet = true;
            return this;
        }
        public Builder end(TerminalTabEnd value) {
            this.end = Field.ofNullable(value);
            return this;
        }
        public Builder faviconUrl(String value) {
            this.faviconUrl = Field.ofNullable(value);
            return this;
        }
        public Builder gitBranch(String value) {
            this.gitBranch = Field.ofNullable(value);
            return this;
        }
        public Builder gitDetached(Boolean value) {
            this.gitDetached = Field.of(value);
            return this;
        }
        public Builder group(String value) {
            this.group = Field.ofNullable(value);
            return this;
        }
        public Builder hostRecordVersion(UInt64 value) {
            this.hostRecordVersion = Field.ofNullable(value);
            return this;
        }
        public Builder kind(TabKind value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder notification(NotificationMarker value) {
            this.notification = Field.ofNullable(value);
            return this;
        }
        public Builder pinned(Boolean value) {
            this.pinned = Field.of(value);
            return this;
        }
        public Builder pinnedUrl(String value) {
            this.pinnedUrl = Field.ofNullable(value);
            return this;
        }
        public Builder programStatus(ShownProgramStatus value) {
            this.programStatus = Field.ofNullable(value);
            return this;
        }
        public Builder relaunch(Object value) {
            this.relaunch = Field.ofNullable(value);
            return this;
        }
        public Builder remote(Object value) {
            this.remote = Field.of(value);
            return this;
        }
        public Builder shortId(String value) {
            this.shortId = Field.of(value);
            return this;
        }
        public Builder size(Size value) {
            this.size = value;
            this.sizeSet = true;
            return this;
        }
        public Builder supportsClearHistoryKeyFallback(Boolean value) {
            this.supportsClearHistoryKeyFallback = Field.of(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder tabResourceId(String value) {
            this.tabResourceId = Field.ofNullable(value);
            return this;
        }
        public Builder terminalHostFallback(String value) {
            this.terminalHostFallback = Field.ofNullable(value);
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = Field.ofNullable(value);
            return this;
        }
        public Builder terminalIncarnation(String value) {
            this.terminalIncarnation = Field.ofNullable(value);
            return this;
        }
        public Builder terminalResourceId(String value) {
            this.terminalResourceId = Field.ofNullable(value);
            return this;
        }
        public Builder terminalState(String value) {
            this.terminalState = Field.ofNullable(value);
            return this;
        }
        public Builder title(String value) {
            this.title = value;
            this.titleSet = true;
            return this;
        }
        public Builder titleActivity(String value) {
            this.titleActivity = Field.ofNullable(value);
            return this;
        }
        public Builder titleText(String value) {
            this.titleText = Field.of(value);
            return this;
        }
        public Builder url(String value) {
            this.url = Field.ofNullable(value);
            return this;
        }
        public Tab build() { return new Tab(this); }
    }
}
