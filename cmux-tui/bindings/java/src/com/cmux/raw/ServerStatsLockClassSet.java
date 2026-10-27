// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsLockClassSet implements WireValue {
    private final ServerStatsLockClass automation;
    private final UInt64 automationDueAdmissions;
    private final UInt64 automationYields;
    private final ServerStatsLockClass frontend;
    private final ServerStatsLockClass program;

    private ServerStatsLockClassSet(Builder builder) {
        if (!builder.automationSet) throw new IllegalArgumentException("automation is required");
        this.automation = Wire.nonNull(builder.automation, "automation");
        if (!builder.automationDueAdmissionsSet) throw new IllegalArgumentException("automation_due_admissions is required");
        this.automationDueAdmissions = Wire.nonNull(builder.automationDueAdmissions, "automation_due_admissions");
        if (!builder.automationYieldsSet) throw new IllegalArgumentException("automation_yields is required");
        this.automationYields = Wire.nonNull(builder.automationYields, "automation_yields");
        if (!builder.frontendSet) throw new IllegalArgumentException("frontend is required");
        this.frontend = Wire.nonNull(builder.frontend, "frontend");
        if (!builder.programSet) throw new IllegalArgumentException("program is required");
        this.program = Wire.nonNull(builder.program, "program");
    }

    public static Builder builder() { return new Builder(); }

    public ServerStatsLockClass automation() { return automation; }
    public UInt64 automationDueAdmissions() { return automationDueAdmissions; }
    public UInt64 automationYields() { return automationYields; }
    public ServerStatsLockClass frontend() { return frontend; }
    public ServerStatsLockClass program() { return program; }

    public static ServerStatsLockClassSet fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsLockClassSet");
        Builder builder = builder();
        Object rawAutomation = Wire.required(object, "automation");
        builder.automation(ServerStatsLockClass.fromWire(rawAutomation));
        Object rawAutomationDueAdmissions = Wire.required(object, "automation_due_admissions");
        builder.automationDueAdmissions(Wire.uint64(rawAutomationDueAdmissions, "ServerStatsLockClassSet.automation_due_admissions"));
        Object rawAutomationYields = Wire.required(object, "automation_yields");
        builder.automationYields(Wire.uint64(rawAutomationYields, "ServerStatsLockClassSet.automation_yields"));
        Object rawFrontend = Wire.required(object, "frontend");
        builder.frontend(ServerStatsLockClass.fromWire(rawFrontend));
        Object rawProgram = Wire.required(object, "program");
        builder.program(ServerStatsLockClass.fromWire(rawProgram));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "automation", automation);
        Wire.put(object, "automation_due_admissions", automationDueAdmissions);
        Wire.put(object, "automation_yields", automationYields);
        Wire.put(object, "frontend", frontend);
        Wire.put(object, "program", program);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsLockClassSet that)) return false;
        return Objects.equals(automation, that.automation) && Objects.equals(automationDueAdmissions, that.automationDueAdmissions) && Objects.equals(automationYields, that.automationYields) && Objects.equals(frontend, that.frontend) && Objects.equals(program, that.program);
    }

    @Override
    public int hashCode() { return Objects.hash(automation, automationDueAdmissions, automationYields, frontend, program); }

    @Override
    public String toString() { return "ServerStatsLockClassSet" + toWire(); }

    public static final class Builder {
        private ServerStatsLockClass automation;
        private boolean automationSet;
        private UInt64 automationDueAdmissions;
        private boolean automationDueAdmissionsSet;
        private UInt64 automationYields;
        private boolean automationYieldsSet;
        private ServerStatsLockClass frontend;
        private boolean frontendSet;
        private ServerStatsLockClass program;
        private boolean programSet;

        public Builder automation(ServerStatsLockClass value) {
            this.automation = value;
            this.automationSet = true;
            return this;
        }
        public Builder automationDueAdmissions(UInt64 value) {
            this.automationDueAdmissions = value;
            this.automationDueAdmissionsSet = true;
            return this;
        }
        public Builder automationYields(UInt64 value) {
            this.automationYields = value;
            this.automationYieldsSet = true;
            return this;
        }
        public Builder frontend(ServerStatsLockClass value) {
            this.frontend = value;
            this.frontendSet = true;
            return this;
        }
        public Builder program(ServerStatsLockClass value) {
            this.program = value;
            this.programSet = true;
            return this;
        }
        public ServerStatsLockClassSet build() { return new ServerStatsLockClassSet(this); }
    }
}
