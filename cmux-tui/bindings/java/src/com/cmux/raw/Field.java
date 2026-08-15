package com.cmux.raw;

import java.util.NoSuchElementException;
import java.util.Objects;
import java.util.function.Function;

/**
 * Preserves the difference between an omitted field, an explicit JSON null,
 * and a concrete value.
 */
public final class Field<T> {
    private static final Field<?> OMITTED = new Field<>(false, null);
    private final boolean present;
    private final T value;

    private Field(boolean present, T value) {
        this.present = present;
        this.value = value;
    }

    @SuppressWarnings("unchecked")
    public static <T> Field<T> omitted() {
        return (Field<T>) OMITTED;
    }

    public static <T> Field<T> of(T value) {
        return new Field<>(true, Objects.requireNonNull(value, "value"));
    }

    public static <T> Field<T> ofNullable(T value) {
        return new Field<>(true, value);
    }

    public boolean isPresent() {
        return present;
    }

    public boolean isNull() {
        return present && value == null;
    }

    public T value() {
        if (!present) {
            throw new NoSuchElementException("field is omitted");
        }
        return value;
    }

    public T orElse(T fallback) {
        return present ? value : fallback;
    }

    public <R> Field<R> map(Function<? super T, ? extends R> mapper) {
        Objects.requireNonNull(mapper, "mapper");
        return present ? Field.ofNullable(value == null ? null : mapper.apply(value)) : Field.omitted();
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof Field<?> that
            && present == that.present
            && Objects.equals(value, that.value);
    }

    @Override
    public int hashCode() {
        return 31 * Boolean.hashCode(present) + Objects.hashCode(value);
    }

    @Override
    public String toString() {
        return present ? "Field[" + value + "]" : "Field.omitted";
    }
}
