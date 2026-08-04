// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum TerminalKey implements WireEnum {
    UNIDENTIFIED("unidentified"),
    BACKQUOTE("backquote"),
    BACKSLASH("backslash"),
    BRACKET_LEFT("bracket-left"),
    BRACKET_RIGHT("bracket-right"),
    COMMA("comma"),
    DIGIT0("digit0"),
    DIGIT1("digit1"),
    DIGIT2("digit2"),
    DIGIT3("digit3"),
    DIGIT4("digit4"),
    DIGIT5("digit5"),
    DIGIT6("digit6"),
    DIGIT7("digit7"),
    DIGIT8("digit8"),
    DIGIT9("digit9"),
    EQUAL("equal"),
    A("a"),
    B("b"),
    C("c"),
    D("d"),
    E("e"),
    F("f"),
    G("g"),
    H("h"),
    I("i"),
    J("j"),
    K("k"),
    L("l"),
    M("m"),
    N("n"),
    O("o"),
    P("p"),
    Q("q"),
    R("r"),
    S("s"),
    T("t"),
    U("u"),
    V("v"),
    W("w"),
    X("x"),
    Y("y"),
    Z("z"),
    MINUS("minus"),
    PERIOD("period"),
    QUOTE("quote"),
    SEMICOLON("semicolon"),
    SLASH("slash"),
    BACKSPACE("backspace"),
    ENTER("enter"),
    SPACE("space"),
    TAB("tab"),
    DELETE("delete"),
    END("end"),
    HOME("home"),
    INSERT("insert"),
    PAGE_DOWN("page-down"),
    PAGE_UP("page-up"),
    ARROW_DOWN("arrow-down"),
    ARROW_LEFT("arrow-left"),
    ARROW_RIGHT("arrow-right"),
    ARROW_UP("arrow-up"),
    NUMPAD0("numpad0"),
    NUMPAD1("numpad1"),
    NUMPAD2("numpad2"),
    NUMPAD3("numpad3"),
    NUMPAD4("numpad4"),
    NUMPAD5("numpad5"),
    NUMPAD6("numpad6"),
    NUMPAD7("numpad7"),
    NUMPAD8("numpad8"),
    NUMPAD9("numpad9"),
    NUMPAD_ADD("numpad-add"),
    NUMPAD_BACKSPACE("numpad-backspace"),
    NUMPAD_COMMA("numpad-comma"),
    NUMPAD_DECIMAL("numpad-decimal"),
    NUMPAD_DIVIDE("numpad-divide"),
    NUMPAD_ENTER("numpad-enter"),
    NUMPAD_EQUAL("numpad-equal"),
    NUMPAD_MULTIPLY("numpad-multiply"),
    NUMPAD_SUBTRACT("numpad-subtract"),
    NUMPAD_UP("numpad-up"),
    NUMPAD_DOWN("numpad-down"),
    NUMPAD_RIGHT("numpad-right"),
    NUMPAD_LEFT("numpad-left"),
    NUMPAD_BEGIN("numpad-begin"),
    NUMPAD_HOME("numpad-home"),
    NUMPAD_END("numpad-end"),
    NUMPAD_INSERT("numpad-insert"),
    NUMPAD_DELETE("numpad-delete"),
    NUMPAD_PAGE_UP("numpad-page-up"),
    NUMPAD_PAGE_DOWN("numpad-page-down"),
    ESCAPE("escape"),
    F1("f1"),
    F2("f2"),
    F3("f3"),
    F4("f4"),
    F5("f5"),
    F6("f6"),
    F7("f7"),
    F8("f8"),
    F9("f9"),
    F10("f10"),
    F11("f11"),
    F12("f12"),
    F13("f13"),
    F14("f14"),
    F15("f15"),
    F16("f16"),
    F17("f17"),
    F18("f18"),
    F19("f19"),
    F20("f20");

    private final Object wireValue;

    TerminalKey(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static TerminalKey fromWire(Object value) {
        for (TerminalKey candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown TerminalKey value " + value, null);
    }
}
