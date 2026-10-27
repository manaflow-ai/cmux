// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable apps-mount request. Protocol v12; authority: local-admin. */
public final class AppsMountRequest implements WireValue {
    private final String app;
    private final Field<Object> context;
    private final String interface_;
    private final String mountId;
    private final Field<AppOrigin> origin;

    private AppsMountRequest(Builder builder) {
        if (!builder.appSet) throw new IllegalArgumentException("app is required");
        this.app = Wire.nonNull(builder.app, "app");
        this.context = builder.context.map(value -> Wire.immutableJson(value));
        if (!builder.interface_Set) throw new IllegalArgumentException("interface is required");
        this.interface_ = Wire.nonNull(builder.interface_, "interface");
        if (!builder.mountIdSet) throw new IllegalArgumentException("mount_id is required");
        this.mountId = Wire.nonNull(builder.mountId, "mount_id");
        this.origin = builder.origin;
    }

    public static Builder builder() { return new Builder(); }

    public String app() { return app; }
    public Field<Object> context() { return context; }
    public String interface_() { return interface_; }
    public String mountId() { return mountId; }
    public Field<AppOrigin> origin() { return origin; }

    public static AppsMountRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppsMountRequest");
        Builder builder = builder();
        Object rawApp = Wire.required(object, "app");
        builder.app(Wire.string(rawApp, "AppsMountRequest.app"));
        Object rawContext = Wire.optional(object, "context");
        if (!Wire.isMissing(rawContext)) {
            builder.context(rawContext == null ? null : Wire.immutableJson(rawContext));
        }
        Object rawInterface = Wire.required(object, "interface");
        builder.interface_(Wire.string(rawInterface, "AppsMountRequest.interface"));
        Object rawMountId = Wire.required(object, "mount_id");
        builder.mountId(Wire.string(rawMountId, "AppsMountRequest.mount_id"));
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(AppOrigin.fromWire(rawOrigin));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "app", app);
        Wire.put(object, "context", context);
        Wire.put(object, "interface", interface_);
        Wire.put(object, "mount_id", mountId);
        Wire.put(object, "origin", origin);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppsMountRequest that)) return false;
        return Objects.equals(app, that.app) && Objects.equals(context, that.context) && Objects.equals(interface_, that.interface_) && Objects.equals(mountId, that.mountId) && Objects.equals(origin, that.origin);
    }

    @Override
    public int hashCode() { return Objects.hash(app, context, interface_, mountId, origin); }

    @Override
    public String toString() { return "AppsMountRequest" + toWire(); }

    public static final class Builder {
        private String app;
        private boolean appSet;
        private Field<Object> context = Field.omitted();
        private String interface_;
        private boolean interface_Set;
        private String mountId;
        private boolean mountIdSet;
        private Field<AppOrigin> origin = Field.omitted();

        public Builder app(String value) {
            this.app = value;
            this.appSet = true;
            return this;
        }
        public Builder context(Object value) {
            this.context = Field.ofNullable(value);
            return this;
        }
        public Builder interface_(String value) {
            this.interface_ = value;
            this.interface_Set = true;
            return this;
        }
        public Builder mountId(String value) {
            this.mountId = value;
            this.mountIdSet = true;
            return this;
        }
        public Builder origin(AppOrigin value) {
            this.origin = Field.of(value);
            return this;
        }
        public AppsMountRequest build() { return new AppsMountRequest(this); }
    }
}
