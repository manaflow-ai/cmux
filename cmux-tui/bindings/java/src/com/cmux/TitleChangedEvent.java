package com.cmux;

public record TitleChangedEvent(long surface, String title) implements CmuxEvent {
    @Override
    public String event() {
        return "title-changed";
    }
}
