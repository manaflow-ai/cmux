package com.cmux;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public record Screen(
    long id,
    String name,
    boolean active,
    long activePane,
    Map<String, Object> layout,
    List<Pane> panes,
    Double viewportBaseWidth,
    List<ViewportSplit> viewportSplits
) {
    public Screen(
        long id,
        String name,
        boolean active,
        long activePane,
        Map<String, Object> layout,
        List<Pane> panes
    ) {
        this(id, name, active, activePane, layout, panes, null, List.of());
    }

    @SuppressWarnings("unchecked")
    static Screen from(Map<String, Object> data) {
        List<Pane> panes = new ArrayList<>();
        Object raw = data.get("panes");
        if (raw instanceof List<?> list) {
            for (Object item : list) {
                panes.add(Pane.from((Map<String, Object>) item));
            }
        }
        List<ViewportSplit> viewportSplits = new ArrayList<>();
        Object rawViewportSplits = data.get("viewport_splits");
        if (rawViewportSplits instanceof List<?> list) {
            for (Object item : list) {
                viewportSplits.add(ViewportSplit.from((Map<String, Object>) item));
            }
        }
        Map<String, Object> layout = data.get("layout") instanceof Map<?, ?> rawLayout
            ? (Map<String, Object>) rawLayout
            : Map.of();
        Object rawViewportBaseWidth = data.get("viewport_base_width");
        Double viewportBaseWidth = rawViewportBaseWidth instanceof Number number
            ? number.doubleValue()
            : rawViewportBaseWidth == null
                ? null
                : Double.parseDouble(String.valueOf(rawViewportBaseWidth));
        return new Screen(
            CmuxClient.asLong(data.get("id")),
            data.get("name") == null ? null : CmuxClient.asString(data.get("name")),
            Boolean.TRUE.equals(data.get("active")),
            CmuxClient.asLong(data.get("active_pane")),
            layout,
            panes,
            viewportBaseWidth,
            viewportSplits
        );
    }
}
