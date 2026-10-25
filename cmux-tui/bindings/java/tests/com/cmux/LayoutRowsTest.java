package com.cmux;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/** rows-v1: a layout document's columns carry their rows. */
public final class LayoutRowsTest {
    private LayoutRowsTest() {}

    private static final String CHAIN = "split_dddddddddddddddddddddddddddddddd";
    private static final String FIRST = "split_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

    private static Map<String, Object> leaf(String pane) {
        return Map.of("kind", "leaf", "pane_id", pane, "tab_ids", List.of());
    }

    private static Map<String, Object> document(Object rows) {
        Map<String, Object> first = new HashMap<>(Map.of(
            "column_id", "split_cccccccccccccccccccccccccccccccc", "width", 0.5,
            "root", Map.of("kind", "split", "split_id", CHAIN, "direction", "vertical", "ratio", 0.6,
                "first", leaf("pane_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
                "second", leaf("pane_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))));
        if (rows != null) first.put("rows", rows);
        Map<String, Object> second = Map.of(
            "column_id", "split_ffffffffffffffffffffffffffffffff", "width", 0.5,
            "root", leaf("pane_cccccccccccccccccccccccccccccccc"));
        Map<String, Object> document = new HashMap<>();
        document.put("version", 1);
        document.put("screen_id", "screen_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        document.put("active_pane_id", "pane_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        document.put("zoomed_pane_id", null);
        document.put("root", Map.of("kind", "viewport", "base_width", 0.5, "columns", List.of(first, second)));
        return document;
    }

    private static List<Layout.Column> columns(Object rows) {
        return ((Layout.Viewport) Client.decodeLayoutDocument(document(rows)).root()).columns();
    }

    public static void main(String[] args) {
        List<Layout.Column> columns = columns(List.of(
            Map.of("row_id", FIRST, "height", 600), Map.of("row_id", CHAIN, "height", 400)));
        List<Layout.Row> rows = columns.get(0).rows();
        if (rows.size() != 2 || rows.get(0).height() != 600 || rows.get(1).height() != 400
            || !rows.get(1).rowId().orElseThrow().value().equals(CHAIN)) {
            throw new AssertionError("rows lost: " + rows);
        }
        if (!columns.get(1).rows().isEmpty()) throw new AssertionError("a one-row column has no rows");
        Layout.Row first = columns(List.of(Map.of("height", 500), Map.of("row_id", CHAIN, "height", 400)))
            .get(0).rows().get(0);
        if (!first.rowId().equals(Optional.empty()) || first.height() != 500) {
            throw new AssertionError("row 1 without an id: " + first);
        }
        for (Object bad : List.<Object>of(
            List.of(Map.of("row_id", FIRST, "height", 600, "width", 1), Map.of("row_id", CHAIN, "height", 400)),
            List.of(Map.of("row_id", FIRST, "height", 50), Map.of("row_id", CHAIN, "height", 400)),
            List.of(Map.of("row_id", FIRST), Map.of("row_id", CHAIN, "height", 400)),
            "rows")) {
            try {
                columns(bad);
                throw new AssertionError("bad rows decoded: " + bad);
            } catch (ProtocolError | IllegalArgumentException expected) {
                // Refusal is the expected result.
            }
        }
    }
}
