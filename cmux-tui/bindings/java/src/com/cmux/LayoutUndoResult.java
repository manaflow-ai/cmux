package com.cmux;

public sealed interface LayoutUndoResult
    permits LayoutUndoUndone, LayoutUndoConfirmationRequired {}
