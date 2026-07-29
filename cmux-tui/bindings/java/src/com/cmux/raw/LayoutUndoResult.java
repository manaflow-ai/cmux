package com.cmux.raw;

public sealed interface LayoutUndoResult
    permits LayoutUndoUndone, LayoutUndoConfirmationRequired {}
