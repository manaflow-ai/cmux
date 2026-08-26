package com.cmux;

import java.util.Optional;

public record StreamItem<T>(Decimal sequence, Optional<Cursor> cursor, T value) {
    public StreamItem {
        cursor = cursor == null ? Optional.empty() : cursor;
    }
}
