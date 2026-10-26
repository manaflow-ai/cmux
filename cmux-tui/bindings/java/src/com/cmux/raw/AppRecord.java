// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppRecord implements WireValue {
    private final boolean available;
    private final String bundleDir;
    private final List<AppPaletteCommand> commands;
    private final boolean enabled;
    private final List<String> grants;
    private final boolean hidden;
    private final AppHiddenAccess hiddenAccess;
    private final boolean hideOnly;
    private final String id;
    private final boolean installed;
    private final Object manifest;
    private final Field<UInt64> revision;
    private final boolean sandboxed;
    private final Map<String, AppScopeClass> scopeClasses;
    private final AppSource source;
    private final AppTier tier;
    private final String version;

    private AppRecord(Builder builder) {
        if (!builder.availableSet) throw new IllegalArgumentException("available is required");
        this.available = builder.available;
        if (!builder.bundleDirSet) throw new IllegalArgumentException("bundle_dir is required");
        this.bundleDir = builder.bundleDir;
        if (!builder.commandsSet) throw new IllegalArgumentException("commands is required");
        this.commands = List.copyOf(Wire.nonNull(builder.commands, "commands"));
        if (!builder.enabledSet) throw new IllegalArgumentException("enabled is required");
        this.enabled = builder.enabled;
        if (!builder.grantsSet) throw new IllegalArgumentException("grants is required");
        this.grants = List.copyOf(Wire.nonNull(builder.grants, "grants"));
        if (!builder.hiddenSet) throw new IllegalArgumentException("hidden is required");
        this.hidden = builder.hidden;
        if (!builder.hiddenAccessSet) throw new IllegalArgumentException("hidden_access is required");
        this.hiddenAccess = Wire.nonNull(builder.hiddenAccess, "hidden_access");
        if (!builder.hideOnlySet) throw new IllegalArgumentException("hide_only is required");
        this.hideOnly = builder.hideOnly;
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.installedSet) throw new IllegalArgumentException("installed is required");
        this.installed = builder.installed;
        if (!builder.manifestSet) throw new IllegalArgumentException("manifest is required");
        this.manifest = builder.manifest == null ? null : Wire.immutableJson(builder.manifest);
        this.revision = builder.revision;
        if (!builder.sandboxedSet) throw new IllegalArgumentException("sandboxed is required");
        this.sandboxed = builder.sandboxed;
        if (!builder.scopeClassesSet) throw new IllegalArgumentException("scope_classes is required");
        this.scopeClasses = Collections.unmodifiableMap(new LinkedHashMap<>(Wire.nonNull(builder.scopeClasses, "scope_classes")));
        if (!builder.sourceSet) throw new IllegalArgumentException("source is required");
        this.source = Wire.nonNull(builder.source, "source");
        if (!builder.tierSet) throw new IllegalArgumentException("tier is required");
        this.tier = Wire.nonNull(builder.tier, "tier");
        if (!builder.versionSet) throw new IllegalArgumentException("version is required");
        this.version = Wire.nonNull(builder.version, "version");
    }

    public static Builder builder() { return new Builder(); }

    public boolean available() { return available; }
    public String bundleDir() { return bundleDir; }
    public List<AppPaletteCommand> commands() { return commands; }
    public boolean enabled() { return enabled; }
    public List<String> grants() { return grants; }
    public boolean hidden() { return hidden; }
    public AppHiddenAccess hiddenAccess() { return hiddenAccess; }
    public boolean hideOnly() { return hideOnly; }
    public String id() { return id; }
    public boolean installed() { return installed; }
    public Object manifest() { return manifest; }
    public Field<UInt64> revision() { return revision; }
    public boolean sandboxed() { return sandboxed; }
    public Map<String, AppScopeClass> scopeClasses() { return scopeClasses; }
    public AppSource source() { return source; }
    public AppTier tier() { return tier; }
    public String version() { return version; }

    public static AppRecord fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppRecord");
        Builder builder = builder();
        Object rawAvailable = Wire.required(object, "available");
        builder.available(Wire.bool(rawAvailable, "AppRecord.available"));
        Object rawBundleDir = Wire.required(object, "bundle_dir");
        builder.bundleDir(rawBundleDir == null ? null : Wire.string(rawBundleDir, "AppRecord.bundle_dir"));
        Object rawCommands = Wire.required(object, "commands");
        builder.commands(Wire.array(rawCommands, "AppRecord.commands", item -> AppPaletteCommand.fromWire(item)));
        Object rawEnabled = Wire.required(object, "enabled");
        builder.enabled(Wire.bool(rawEnabled, "AppRecord.enabled"));
        Object rawGrants = Wire.required(object, "grants");
        builder.grants(Wire.array(rawGrants, "AppRecord.grants", item -> Wire.string(item, "AppRecord.grants item")));
        Object rawHidden = Wire.required(object, "hidden");
        builder.hidden(Wire.bool(rawHidden, "AppRecord.hidden"));
        Object rawHiddenAccess = Wire.required(object, "hidden_access");
        builder.hiddenAccess(AppHiddenAccess.fromWire(rawHiddenAccess));
        Object rawHideOnly = Wire.required(object, "hide_only");
        builder.hideOnly(Wire.bool(rawHideOnly, "AppRecord.hide_only"));
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "AppRecord.id"));
        Object rawInstalled = Wire.required(object, "installed");
        builder.installed(Wire.bool(rawInstalled, "AppRecord.installed"));
        Object rawManifest = Wire.required(object, "manifest");
        builder.manifest(rawManifest == null ? null : Wire.immutableJson(rawManifest));
        Object rawRevision = Wire.optional(object, "revision");
        if (!Wire.isMissing(rawRevision)) {
            builder.revision(Wire.uint64(rawRevision, "AppRecord.revision"));
        }
        Object rawSandboxed = Wire.required(object, "sandboxed");
        builder.sandboxed(Wire.bool(rawSandboxed, "AppRecord.sandboxed"));
        Object rawScopeClasses = Wire.required(object, "scope_classes");
        builder.scopeClasses(Wire.map(rawScopeClasses, "AppRecord.scope_classes", item -> AppScopeClass.fromWire(item)));
        Object rawSource = Wire.required(object, "source");
        builder.source(AppSource.fromWire(rawSource));
        Object rawTier = Wire.required(object, "tier");
        builder.tier(AppTier.fromWire(rawTier));
        Object rawVersion = Wire.required(object, "version");
        builder.version(Wire.string(rawVersion, "AppRecord.version"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "available", available);
        Wire.put(object, "bundle_dir", bundleDir);
        Wire.put(object, "commands", commands);
        Wire.put(object, "enabled", enabled);
        Wire.put(object, "grants", grants);
        Wire.put(object, "hidden", hidden);
        Wire.put(object, "hidden_access", hiddenAccess);
        Wire.put(object, "hide_only", hideOnly);
        Wire.put(object, "id", id);
        Wire.put(object, "installed", installed);
        Wire.put(object, "manifest", manifest);
        Wire.put(object, "revision", revision);
        Wire.put(object, "sandboxed", sandboxed);
        Wire.put(object, "scope_classes", scopeClasses);
        Wire.put(object, "source", source);
        Wire.put(object, "tier", tier);
        Wire.put(object, "version", version);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppRecord that)) return false;
        return Objects.equals(available, that.available) && Objects.equals(bundleDir, that.bundleDir) && Objects.equals(commands, that.commands) && Objects.equals(enabled, that.enabled) && Objects.equals(grants, that.grants) && Objects.equals(hidden, that.hidden) && Objects.equals(hiddenAccess, that.hiddenAccess) && Objects.equals(hideOnly, that.hideOnly) && Objects.equals(id, that.id) && Objects.equals(installed, that.installed) && Objects.equals(manifest, that.manifest) && Objects.equals(revision, that.revision) && Objects.equals(sandboxed, that.sandboxed) && Objects.equals(scopeClasses, that.scopeClasses) && Objects.equals(source, that.source) && Objects.equals(tier, that.tier) && Objects.equals(version, that.version);
    }

    @Override
    public int hashCode() { return Objects.hash(available, bundleDir, commands, enabled, grants, hidden, hiddenAccess, hideOnly, id, installed, manifest, revision, sandboxed, scopeClasses, source, tier, version); }

    @Override
    public String toString() { return "AppRecord" + toWire(); }

    public static final class Builder {
        private Boolean available;
        private boolean availableSet;
        private String bundleDir;
        private boolean bundleDirSet;
        private List<AppPaletteCommand> commands;
        private boolean commandsSet;
        private Boolean enabled;
        private boolean enabledSet;
        private List<String> grants;
        private boolean grantsSet;
        private Boolean hidden;
        private boolean hiddenSet;
        private AppHiddenAccess hiddenAccess;
        private boolean hiddenAccessSet;
        private Boolean hideOnly;
        private boolean hideOnlySet;
        private String id;
        private boolean idSet;
        private Boolean installed;
        private boolean installedSet;
        private Object manifest;
        private boolean manifestSet;
        private Field<UInt64> revision = Field.omitted();
        private Boolean sandboxed;
        private boolean sandboxedSet;
        private Map<String, AppScopeClass> scopeClasses;
        private boolean scopeClassesSet;
        private AppSource source;
        private boolean sourceSet;
        private AppTier tier;
        private boolean tierSet;
        private String version;
        private boolean versionSet;

        public Builder available(boolean value) {
            this.available = value;
            this.availableSet = true;
            return this;
        }
        public Builder bundleDir(String value) {
            this.bundleDir = value;
            this.bundleDirSet = true;
            return this;
        }
        public Builder commands(List<AppPaletteCommand> value) {
            this.commands = value;
            this.commandsSet = true;
            return this;
        }
        public Builder enabled(boolean value) {
            this.enabled = value;
            this.enabledSet = true;
            return this;
        }
        public Builder grants(List<String> value) {
            this.grants = value;
            this.grantsSet = true;
            return this;
        }
        public Builder hidden(boolean value) {
            this.hidden = value;
            this.hiddenSet = true;
            return this;
        }
        public Builder hiddenAccess(AppHiddenAccess value) {
            this.hiddenAccess = value;
            this.hiddenAccessSet = true;
            return this;
        }
        public Builder hideOnly(boolean value) {
            this.hideOnly = value;
            this.hideOnlySet = true;
            return this;
        }
        public Builder id(String value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder installed(boolean value) {
            this.installed = value;
            this.installedSet = true;
            return this;
        }
        public Builder manifest(Object value) {
            this.manifest = value;
            this.manifestSet = true;
            return this;
        }
        public Builder revision(UInt64 value) {
            this.revision = Field.of(value);
            return this;
        }
        public Builder sandboxed(boolean value) {
            this.sandboxed = value;
            this.sandboxedSet = true;
            return this;
        }
        public Builder scopeClasses(Map<String, AppScopeClass> value) {
            this.scopeClasses = value;
            this.scopeClassesSet = true;
            return this;
        }
        public Builder source(AppSource value) {
            this.source = value;
            this.sourceSet = true;
            return this;
        }
        public Builder tier(AppTier value) {
            this.tier = value;
            this.tierSet = true;
            return this;
        }
        public Builder version(String value) {
            this.version = value;
            this.versionSet = true;
            return this;
        }
        public AppRecord build() { return new AppRecord(this); }
    }
}
