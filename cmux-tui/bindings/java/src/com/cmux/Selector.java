package com.cmux;

import java.util.Objects;
import java.util.Optional;

/** Typed ID, current resource, or exact-name selector. */
public final class Selector<I extends Ids.Id> {
    public enum Kind { ID, CURRENT, NAME }

    private final Kind kind;
    private final I id;
    private final String name;

    private Selector(Kind kind, I id, String name) {
        this.kind = kind;
        this.id = id;
        this.name = name;
    }

    public static <I extends Ids.Id> Selector<I> id(I id) {
        return new Selector<>(Kind.ID, Objects.requireNonNull(id, "id"), null);
    }

    public static <I extends Ids.Id> Selector<I> current() {
        return new Selector<>(Kind.CURRENT, null, null);
    }

    public static <I extends Ids.Id> Selector<I> name(String exactName) {
        return new Selector<>(Kind.NAME, null, Objects.requireNonNull(exactName, "exactName"));
    }

    public Kind kind() {
        return kind;
    }

    public Optional<I> id() {
        return Optional.ofNullable(id);
    }

    public Optional<String> name() {
        return Optional.ofNullable(name);
    }

    public String toWire() {
        return switch (kind) {
            case ID -> id.value();
            case CURRENT -> "current";
            case NAME -> "name:" + name;
        };
    }

    @Override
    public String toString() {
        return toWire();
    }
}
