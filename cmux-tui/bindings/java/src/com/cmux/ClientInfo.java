package com.cmux;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public record ClientInfo(
    long client,
    String transport,
    String name,
    String kind,
    long connectedSeconds,
    List<Long> attached,
    List<ClientSurfaceSize> sizes,
    boolean self
) {
    static ClientInfo from(Map<String, Object> data) {
        return new ClientInfo(
            CmuxClient.asLong(data.get("client")),
            CmuxClient.asString(data.get("transport")),
            data.get("name") == null ? null : CmuxClient.asString(data.get("name")),
            data.get("kind") == null ? null : CmuxClient.asString(data.get("kind")),
            CmuxClient.asLong(data.get("connected_seconds")),
            attached(data.get("attached")),
            sizes(
                data.get("sizes"),
                data.get("size_participating") instanceof Boolean value ? value : Boolean.TRUE
            ),
            Boolean.TRUE.equals(data.get("self"))
        );
    }

    private static List<Long> attached(Object value) {
        if (!(value instanceof List<?> values)) {
            return List.of();
        }
        List<Long> attached = new ArrayList<>(values.size());
        for (Object item : values) {
            attached.add(CmuxClient.asLong(item));
        }
        return List.copyOf(attached);
    }

    @SuppressWarnings("unchecked")
    private static List<ClientSurfaceSize> sizes(Object value, Boolean fallbackParticipation) {
        if (!(value instanceof List<?> values)) {
            return List.of();
        }
        List<ClientSurfaceSize> sizes = new ArrayList<>(values.size());
        for (Object item : values) {
            if (item instanceof Map<?, ?> map) {
                sizes.add(ClientSurfaceSize.from(
                    (Map<String, Object>) map,
                    fallbackParticipation
                ));
            }
        }
        return List.copyOf(sizes);
    }
}
