package com.cmux.raw;

import java.util.List;

public record LayoutUndoConfirmationRequired(
    long screen,
    long revision,
    List<Long> closesPanes
) implements LayoutUndoResult {}
