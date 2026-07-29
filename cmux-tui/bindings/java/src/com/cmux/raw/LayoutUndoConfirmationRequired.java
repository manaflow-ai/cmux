package com.cmux;

import java.util.List;

public record LayoutUndoConfirmationRequired(
    long screen,
    long revision,
    List<Long> closesPanes
) implements LayoutUndoResult {}
