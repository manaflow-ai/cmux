// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsDiskJournalKind implements WireValue {
    private final UInt64 budgetBytesPerDay;
    private final UInt64 bytesPerDay;
    private final String kind;
    private final boolean overBudget;
    private final UInt64 sampleBytes;
    private final UInt64 sampleRows;

    private ServerStatsDiskJournalKind(Builder builder) {
        if (!builder.budgetBytesPerDaySet) throw new IllegalArgumentException("budget_bytes_per_day is required");
        this.budgetBytesPerDay = Wire.nonNull(builder.budgetBytesPerDay, "budget_bytes_per_day");
        if (!builder.bytesPerDaySet) throw new IllegalArgumentException("bytes_per_day is required");
        this.bytesPerDay = builder.bytesPerDay;
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        if (!builder.overBudgetSet) throw new IllegalArgumentException("over_budget is required");
        this.overBudget = builder.overBudget;
        if (!builder.sampleBytesSet) throw new IllegalArgumentException("sample_bytes is required");
        this.sampleBytes = Wire.nonNull(builder.sampleBytes, "sample_bytes");
        if (!builder.sampleRowsSet) throw new IllegalArgumentException("sample_rows is required");
        this.sampleRows = Wire.nonNull(builder.sampleRows, "sample_rows");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 budgetBytesPerDay() { return budgetBytesPerDay; }
    public UInt64 bytesPerDay() { return bytesPerDay; }
    public String kind() { return kind; }
    public boolean overBudget() { return overBudget; }
    public UInt64 sampleBytes() { return sampleBytes; }
    public UInt64 sampleRows() { return sampleRows; }

    public static ServerStatsDiskJournalKind fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsDiskJournalKind");
        Builder builder = builder();
        Object rawBudgetBytesPerDay = Wire.required(object, "budget_bytes_per_day");
        builder.budgetBytesPerDay(Wire.uint64(rawBudgetBytesPerDay, "ServerStatsDiskJournalKind.budget_bytes_per_day"));
        Object rawBytesPerDay = Wire.required(object, "bytes_per_day");
        builder.bytesPerDay(rawBytesPerDay == null ? null : Wire.uint64(rawBytesPerDay, "ServerStatsDiskJournalKind.bytes_per_day"));
        Object rawKind = Wire.required(object, "kind");
        builder.kind(Wire.string(rawKind, "ServerStatsDiskJournalKind.kind"));
        Object rawOverBudget = Wire.required(object, "over_budget");
        builder.overBudget(Wire.bool(rawOverBudget, "ServerStatsDiskJournalKind.over_budget"));
        Object rawSampleBytes = Wire.required(object, "sample_bytes");
        builder.sampleBytes(Wire.uint64(rawSampleBytes, "ServerStatsDiskJournalKind.sample_bytes"));
        Object rawSampleRows = Wire.required(object, "sample_rows");
        builder.sampleRows(Wire.uint64(rawSampleRows, "ServerStatsDiskJournalKind.sample_rows"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "budget_bytes_per_day", budgetBytesPerDay);
        Wire.put(object, "bytes_per_day", bytesPerDay);
        Wire.put(object, "kind", kind);
        Wire.put(object, "over_budget", overBudget);
        Wire.put(object, "sample_bytes", sampleBytes);
        Wire.put(object, "sample_rows", sampleRows);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsDiskJournalKind that)) return false;
        return Objects.equals(budgetBytesPerDay, that.budgetBytesPerDay) && Objects.equals(bytesPerDay, that.bytesPerDay) && Objects.equals(kind, that.kind) && Objects.equals(overBudget, that.overBudget) && Objects.equals(sampleBytes, that.sampleBytes) && Objects.equals(sampleRows, that.sampleRows);
    }

    @Override
    public int hashCode() { return Objects.hash(budgetBytesPerDay, bytesPerDay, kind, overBudget, sampleBytes, sampleRows); }

    @Override
    public String toString() { return "ServerStatsDiskJournalKind" + toWire(); }

    public static final class Builder {
        private UInt64 budgetBytesPerDay;
        private boolean budgetBytesPerDaySet;
        private UInt64 bytesPerDay;
        private boolean bytesPerDaySet;
        private String kind;
        private boolean kindSet;
        private Boolean overBudget;
        private boolean overBudgetSet;
        private UInt64 sampleBytes;
        private boolean sampleBytesSet;
        private UInt64 sampleRows;
        private boolean sampleRowsSet;

        public Builder budgetBytesPerDay(UInt64 value) {
            this.budgetBytesPerDay = value;
            this.budgetBytesPerDaySet = true;
            return this;
        }
        public Builder bytesPerDay(UInt64 value) {
            this.bytesPerDay = value;
            this.bytesPerDaySet = true;
            return this;
        }
        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder overBudget(boolean value) {
            this.overBudget = value;
            this.overBudgetSet = true;
            return this;
        }
        public Builder sampleBytes(UInt64 value) {
            this.sampleBytes = value;
            this.sampleBytesSet = true;
            return this;
        }
        public Builder sampleRows(UInt64 value) {
            this.sampleRows = value;
            this.sampleRowsSet = true;
            return this;
        }
        public ServerStatsDiskJournalKind build() { return new ServerStatsDiskJournalKind(this); }
    }
}
