// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class Appearance implements WireValue {
    private final Object accent;
    private final AppearanceBackground background;
    private final AppearanceChat chat;
    private final Object chromeStyle;
    private final Object glassTransparency;
    private final AppearanceGroups groups;
    private final Object hue;
    private final UInt64 revision;
    private final Object saturation;
    private final Object sidebarSurface;
    private final AppearanceTerminal terminal;
    private final AppearanceTheme theme;

    private Appearance(Builder builder) {
        if (!builder.accentSet) throw new IllegalArgumentException("accent is required");
        this.accent = builder.accent == null ? null : Wire.immutableJson(builder.accent);
        if (!builder.backgroundSet) throw new IllegalArgumentException("background is required");
        this.background = builder.background;
        if (!builder.chatSet) throw new IllegalArgumentException("chat is required");
        this.chat = Wire.nonNull(builder.chat, "chat");
        if (!builder.chromeStyleSet) throw new IllegalArgumentException("chrome_style is required");
        this.chromeStyle = builder.chromeStyle == null ? null : Wire.immutableJson(builder.chromeStyle);
        if (!builder.glassTransparencySet) throw new IllegalArgumentException("glass_transparency is required");
        this.glassTransparency = builder.glassTransparency == null ? null : Wire.immutableJson(builder.glassTransparency);
        if (!builder.groupsSet) throw new IllegalArgumentException("groups is required");
        this.groups = Wire.nonNull(builder.groups, "groups");
        if (!builder.hueSet) throw new IllegalArgumentException("hue is required");
        this.hue = builder.hue == null ? null : Wire.immutableJson(builder.hue);
        if (!builder.revisionSet) throw new IllegalArgumentException("revision is required");
        this.revision = Wire.nonNull(builder.revision, "revision");
        if (!builder.saturationSet) throw new IllegalArgumentException("saturation is required");
        this.saturation = builder.saturation == null ? null : Wire.immutableJson(builder.saturation);
        if (!builder.sidebarSurfaceSet) throw new IllegalArgumentException("sidebar_surface is required");
        this.sidebarSurface = builder.sidebarSurface == null ? null : Wire.immutableJson(builder.sidebarSurface);
        if (!builder.terminalSet) throw new IllegalArgumentException("terminal is required");
        this.terminal = Wire.nonNull(builder.terminal, "terminal");
        if (!builder.themeSet) throw new IllegalArgumentException("theme is required");
        this.theme = Wire.nonNull(builder.theme, "theme");
    }

    public static Builder builder() { return new Builder(); }

    public Object accent() { return accent; }
    public AppearanceBackground background() { return background; }
    public AppearanceChat chat() { return chat; }
    public Object chromeStyle() { return chromeStyle; }
    public Object glassTransparency() { return glassTransparency; }
    public AppearanceGroups groups() { return groups; }
    public Object hue() { return hue; }
    public UInt64 revision() { return revision; }
    public Object saturation() { return saturation; }
    public Object sidebarSurface() { return sidebarSurface; }
    public AppearanceTerminal terminal() { return terminal; }
    public AppearanceTheme theme() { return theme; }

    public static Appearance fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "Appearance");
        Builder builder = builder();
        Object rawAccent = Wire.required(object, "accent");
        builder.accent(rawAccent == null ? null : Wire.immutableJson(rawAccent));
        Object rawBackground = Wire.required(object, "background");
        builder.background(rawBackground == null ? null : AppearanceBackground.fromWire(rawBackground));
        Object rawChat = Wire.required(object, "chat");
        builder.chat(AppearanceChat.fromWire(rawChat));
        Object rawChromeStyle = Wire.required(object, "chrome_style");
        builder.chromeStyle(rawChromeStyle == null ? null : Wire.immutableJson(rawChromeStyle));
        Object rawGlassTransparency = Wire.required(object, "glass_transparency");
        builder.glassTransparency(rawGlassTransparency == null ? null : Wire.immutableJson(rawGlassTransparency));
        Object rawGroups = Wire.required(object, "groups");
        builder.groups(AppearanceGroups.fromWire(rawGroups));
        Object rawHue = Wire.required(object, "hue");
        builder.hue(rawHue == null ? null : Wire.immutableJson(rawHue));
        Object rawRevision = Wire.required(object, "revision");
        builder.revision(Wire.uint64(rawRevision, "Appearance.revision"));
        Object rawSaturation = Wire.required(object, "saturation");
        builder.saturation(rawSaturation == null ? null : Wire.immutableJson(rawSaturation));
        Object rawSidebarSurface = Wire.required(object, "sidebar_surface");
        builder.sidebarSurface(rawSidebarSurface == null ? null : Wire.immutableJson(rawSidebarSurface));
        Object rawTerminal = Wire.required(object, "terminal");
        builder.terminal(AppearanceTerminal.fromWire(rawTerminal));
        Object rawTheme = Wire.required(object, "theme");
        builder.theme(AppearanceTheme.fromWire(rawTheme));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "accent", accent);
        Wire.put(object, "background", background);
        Wire.put(object, "chat", chat);
        Wire.put(object, "chrome_style", chromeStyle);
        Wire.put(object, "glass_transparency", glassTransparency);
        Wire.put(object, "groups", groups);
        Wire.put(object, "hue", hue);
        Wire.put(object, "revision", revision);
        Wire.put(object, "saturation", saturation);
        Wire.put(object, "sidebar_surface", sidebarSurface);
        Wire.put(object, "terminal", terminal);
        Wire.put(object, "theme", theme);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof Appearance that)) return false;
        return Objects.equals(accent, that.accent) && Objects.equals(background, that.background) && Objects.equals(chat, that.chat) && Objects.equals(chromeStyle, that.chromeStyle) && Objects.equals(glassTransparency, that.glassTransparency) && Objects.equals(groups, that.groups) && Objects.equals(hue, that.hue) && Objects.equals(revision, that.revision) && Objects.equals(saturation, that.saturation) && Objects.equals(sidebarSurface, that.sidebarSurface) && Objects.equals(terminal, that.terminal) && Objects.equals(theme, that.theme);
    }

    @Override
    public int hashCode() { return Objects.hash(accent, background, chat, chromeStyle, glassTransparency, groups, hue, revision, saturation, sidebarSurface, terminal, theme); }

    @Override
    public String toString() { return "Appearance" + toWire(); }

    public static final class Builder {
        private Object accent;
        private boolean accentSet;
        private AppearanceBackground background;
        private boolean backgroundSet;
        private AppearanceChat chat;
        private boolean chatSet;
        private Object chromeStyle;
        private boolean chromeStyleSet;
        private Object glassTransparency;
        private boolean glassTransparencySet;
        private AppearanceGroups groups;
        private boolean groupsSet;
        private Object hue;
        private boolean hueSet;
        private UInt64 revision;
        private boolean revisionSet;
        private Object saturation;
        private boolean saturationSet;
        private Object sidebarSurface;
        private boolean sidebarSurfaceSet;
        private AppearanceTerminal terminal;
        private boolean terminalSet;
        private AppearanceTheme theme;
        private boolean themeSet;

        public Builder accent(Object value) {
            this.accent = value;
            this.accentSet = true;
            return this;
        }
        public Builder background(AppearanceBackground value) {
            this.background = value;
            this.backgroundSet = true;
            return this;
        }
        public Builder chat(AppearanceChat value) {
            this.chat = value;
            this.chatSet = true;
            return this;
        }
        public Builder chromeStyle(Object value) {
            this.chromeStyle = value;
            this.chromeStyleSet = true;
            return this;
        }
        public Builder glassTransparency(Object value) {
            this.glassTransparency = value;
            this.glassTransparencySet = true;
            return this;
        }
        public Builder groups(AppearanceGroups value) {
            this.groups = value;
            this.groupsSet = true;
            return this;
        }
        public Builder hue(Object value) {
            this.hue = value;
            this.hueSet = true;
            return this;
        }
        public Builder revision(UInt64 value) {
            this.revision = value;
            this.revisionSet = true;
            return this;
        }
        public Builder saturation(Object value) {
            this.saturation = value;
            this.saturationSet = true;
            return this;
        }
        public Builder sidebarSurface(Object value) {
            this.sidebarSurface = value;
            this.sidebarSurfaceSet = true;
            return this;
        }
        public Builder terminal(AppearanceTerminal value) {
            this.terminal = value;
            this.terminalSet = true;
            return this;
        }
        public Builder theme(AppearanceTheme value) {
            this.theme = value;
            this.themeSet = true;
            return this;
        }
        public Appearance build() { return new Appearance(this); }
    }
}
