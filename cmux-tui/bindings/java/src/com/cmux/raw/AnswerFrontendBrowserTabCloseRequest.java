// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable answer-frontend-browser-tab-close request. Protocol v12; authority: control. */
public final class AnswerFrontendBrowserTabCloseRequest implements WireValue {
    /** closing: the close started; the tab stays until report-frontend-browser-tab-removed. cancelled: the page vetoed the close (beforeunload). */
    private final AnswerFrontendBrowserTabCloseRequestOutcome outcome;
    private final String requestId;

    private AnswerFrontendBrowserTabCloseRequest(Builder builder) {
        if (!builder.outcomeSet) throw new IllegalArgumentException("outcome is required");
        this.outcome = Wire.nonNull(builder.outcome, "outcome");
        if (!builder.requestIdSet) throw new IllegalArgumentException("request_id is required");
        this.requestId = Wire.nonNull(builder.requestId, "request_id");
    }

    public static Builder builder() { return new Builder(); }

    public AnswerFrontendBrowserTabCloseRequestOutcome outcome() { return outcome; }
    public String requestId() { return requestId; }

    public static AnswerFrontendBrowserTabCloseRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AnswerFrontendBrowserTabCloseRequest");
        Builder builder = builder();
        Object rawOutcome = Wire.required(object, "outcome");
        builder.outcome(AnswerFrontendBrowserTabCloseRequestOutcome.fromWire(rawOutcome));
        Object rawRequestId = Wire.required(object, "request_id");
        builder.requestId(Wire.string(rawRequestId, "AnswerFrontendBrowserTabCloseRequest.request_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "outcome", outcome);
        Wire.put(object, "request_id", requestId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AnswerFrontendBrowserTabCloseRequest that)) return false;
        return Objects.equals(outcome, that.outcome) && Objects.equals(requestId, that.requestId);
    }

    @Override
    public int hashCode() { return Objects.hash(outcome, requestId); }

    @Override
    public String toString() { return "AnswerFrontendBrowserTabCloseRequest" + toWire(); }

    public static final class Builder {
        private AnswerFrontendBrowserTabCloseRequestOutcome outcome;
        private boolean outcomeSet;
        private String requestId;
        private boolean requestIdSet;

        public Builder outcome(AnswerFrontendBrowserTabCloseRequestOutcome value) {
            this.outcome = value;
            this.outcomeSet = true;
            return this;
        }
        public Builder requestId(String value) {
            this.requestId = value;
            this.requestIdSet = true;
            return this;
        }
        public AnswerFrontendBrowserTabCloseRequest build() { return new AnswerFrontendBrowserTabCloseRequest(this); }
    }
}
