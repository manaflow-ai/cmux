package com.cmux;

import java.util.Arrays;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** Snapshot, frame, state, or preserved future browser attachment item. */
public record BrowserAttachmentItem(
    String kind,
    Optional<Snapshots.BrowserSnapshot> browser,
    Optional<Snapshots.PixelSize> size,
    Optional<String> url,
    Optional<String> title,
    Optional<Boolean> loading,
    Optional<String> mimeType,
    byte[] frame,
    Optional<Integer> widthPX,
    Optional<Integer> heightPX,
    Map<String, Object> raw
) {
    public BrowserAttachmentItem {
        Objects.requireNonNull(kind, "kind");
        browser = browser == null ? Optional.empty() : browser;
        size = size == null ? Optional.empty() : size;
        url = url == null ? Optional.empty() : url;
        title = title == null ? Optional.empty() : title;
        loading = loading == null ? Optional.empty() : loading;
        mimeType = mimeType == null ? Optional.empty() : mimeType;
        frame = frame == null ? new byte[0] : Arrays.copyOf(frame, frame.length);
        widthPX = widthPX == null ? Optional.empty() : widthPX;
        heightPX = heightPX == null ? Optional.empty() : heightPX;
        raw = raw == null ? Map.of() : Map.copyOf(raw);
    }

    @Override
    public byte[] frame() {
        return Arrays.copyOf(frame, frame.length);
    }
}
