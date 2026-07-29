package com.cmux.raw;

public enum TerminalKeyAction {
    PRESS("press"),
    RELEASE("release"),
    REPEAT("repeat");

    private final String wireName;

    TerminalKeyAction(String wireName) {
        this.wireName = wireName;
    }

    public String wireName() {
        return wireName;
    }
}
