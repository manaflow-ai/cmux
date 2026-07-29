package com.cmux;

public record TreeChangedEvent() implements CmuxEvent {
    public String event() {
        return "tree-changed";
    }
}
