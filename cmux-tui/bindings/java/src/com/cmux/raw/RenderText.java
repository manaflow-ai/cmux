package com.cmux.raw;

import com.cmux.raw.RenderRow;
import com.cmux.raw.RenderRun;
import java.util.List;
import java.util.Objects;

/** Plain-text projections of generated styled-render models. */
public final class RenderText {
    private RenderText() {}

    /** Returns a run's text while discarding its color, attributes, underline, and width hint. */
    public static String plainText(RenderRun run) {
        return Objects.requireNonNull(run, "run").text();
    }

    /** Concatenates a row's ordered runs without adding a newline. */
    public static String plainText(RenderRow row) {
        Objects.requireNonNull(row, "row");
        StringBuilder text = new StringBuilder();
        for (RenderRun run : row.runs()) {
            text.append(plainText(run));
        }
        return text.toString();
    }

    /** Joins rows with one newline between rows and no trailing newline. */
    public static String plainText(List<RenderRow> rows) {
        Objects.requireNonNull(rows, "rows");
        StringBuilder text = new StringBuilder();
        for (int index = 0; index < rows.size(); index++) {
            if (index > 0) {
                text.append('\n');
            }
            text.append(plainText(rows.get(index)));
        }
        return text.toString();
    }
}
