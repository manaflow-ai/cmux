package com.cmux;

import com.cmux.internal.Operations;
import com.cmux.internal.Wire;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** A browser resource. */
public final class Browser {
    private final Client client;
    private final Route route;
    private final Selector<Ids.BrowserId> selector;
    private volatile Snapshots.BrowserSnapshot snapshot;

    Browser(Client client, Route route, Selector<Ids.BrowserId> selector) {
        this(client, route, selector, null);
    }

    Browser(
        Client client,
        Route route,
        Selector<Ids.BrowserId> selector,
        Snapshots.BrowserSnapshot snapshot
    ) {
        this.client = Objects.requireNonNull(client, "client");
        this.route = Objects.requireNonNull(route, "route");
        this.selector = Objects.requireNonNull(selector, "selector");
        this.snapshot = snapshot;
    }

    public Optional<Snapshots.BrowserSnapshot> cached() {
        return Optional.ofNullable(snapshot);
    }

    public Snapshots.BrowserSnapshot refresh() {
        snapshot = Client.decodeBrowser(Client.resourcePayload(
            client.request(Operations.BROWSER_GET, params(), null),
            Wire.BROWSER
        ));
        return snapshot;
    }

    public MutationResult<Snapshots.BrowserSnapshot> navigate(
        Options.Navigate options
    ) {
        Map<String, Object> params = mutationParams(options.mutation());
        params.put(Wire.URL, options.url());
        return mutateSnapshot(Operations.BROWSER_NAVIGATE, params, options.mutation());
    }

    public MutationResult<Snapshots.BrowserSnapshot> back(Options.Mutation options) {
        return mutateSnapshot(
            Operations.BROWSER_BACK, mutationParams(options), options
        );
    }

    public MutationResult<Snapshots.BrowserSnapshot> forward(Options.Mutation options) {
        return mutateSnapshot(
            Operations.BROWSER_FORWARD, mutationParams(options), options
        );
    }

    public MutationResult<Snapshots.BrowserSnapshot> reload(Options.Mutation options) {
        return mutateSnapshot(
            Operations.BROWSER_RELOAD, mutationParams(options), options
        );
    }

    public MutationResult<Snapshots.BrowserSnapshot> activate(
        Options.Mutation options
    ) {
        return mutateSnapshot(
            Operations.BROWSER_ACTIVATE, mutationParams(options), options
        );
    }

    public MutationResult<EmptyResult> key(Options.Key options) {
        Map<String, Object> params = mutationParams(options.mutation());
        params.putAll(options.key());
        return emptyMutation(Operations.BROWSER_INPUT_KEY, params, options.mutation());
    }

    public MutationResult<EmptyResult> text(Options.Text options) {
        Map<String, Object> params = mutationParams(options.mutation());
        params.put(Wire.TEXT, options.text());
        return emptyMutation(Operations.BROWSER_INPUT_TEXT, params, options.mutation());
    }

    public MutationResult<EmptyResult> mouse(Options.BrowserMouse options) {
        Map<String, Object> params = mutationParams(options.mutation());
        params.putAll(options.mouse());
        params.put(Wire.POINTER_FRAME_SEQ, options.pointerFrameSeq());
        return emptyMutation(
            Operations.BROWSER_INPUT_MOUSE, params, options.mutation()
        );
    }

    public MutationResult<EmptyResult> wheel(Options.Wheel options) {
        Map<String, Object> params = mutationParams(options.mutation());
        params.put("delta_x", options.deltaX());
        params.put("delta_y", options.deltaY());
        params.put("x_px", options.x());
        params.put("y_px", options.y());
        params.put(Wire.POINTER_FRAME_SEQ, options.pointerFrameSeq());
        return emptyMutation(
            Operations.BROWSER_INPUT_WHEEL, params, options.mutation()
        );
    }

    public Results.BrowserViewerResizeResult resizeViewer(
        Options.ViewerSize options
    ) {
        Map<String, Object> params = params();
        params.putAll(options.control().extra());
        params.put(Wire.ATTACHMENT_LEASE, options.attachmentLease());
        params.put("width_px", options.width());
        params.put("height_px", options.height());
        return Client.decodeBrowserViewerResize(client.requestValue(
            Operations.BROWSER_VIEWER_RESIZE, params, null
        ));
    }

    public Results.ViewerReleaseResult releaseViewer(Options.ViewAttachment options) {
        Map<String, Object> params = params();
        params.putAll(options.control().extra());
        params.put(Wire.ATTACHMENT_LEASE, options.attachmentLease());
        return Client.decodeViewerRelease(client.requestValue(
            Operations.BROWSER_VIEWER_RELEASE, params, null
        ));
    }

    public ResourceStream<BrowserAttachmentItem> attach(
        Options.BrowserAttach options
    ) {
        Map<String, Object> params = params();
        params.putAll(options.stream().extra());
        options.width().ifPresent(value -> params.put("width_px", value));
        options.height().ifPresent(value -> params.put("height_px", value));
        return client.openStream(
            Operations.BROWSER_ATTACH,
            params,
            (value, cursor) -> decodeAttachment(value, cursor)
        );
    }

    public MutationResult<EmptyResult> close(Options.Mutation options) {
        return emptyMutation(
            Operations.BROWSER_CLOSE, mutationParams(options), options
        );
    }

    private Map<String, Object> params() {
        return route.target(Wire.BROWSER, selector);
    }

    private Map<String, Object> mutationParams(Options.Mutation options) {
        Map<String, Object> params = params();
        params.putAll(options.extra());
        return params;
    }

    private MutationResult<Snapshots.BrowserSnapshot> mutateSnapshot(
        Operations operation,
        Map<String, Object> params,
        Options.Mutation options
    ) {
        Client.MutationResponse response = client.mutation(operation, params, options);
        snapshot = Client.decodeBrowser(Client.resourcePayload(
            response.result(), Wire.BROWSER
        ));
        return response.parts().withValue(snapshot);
    }

    private MutationResult<EmptyResult> emptyMutation(
        Operations operation,
        Map<String, Object> params,
        Options.Mutation options
    ) {
        Client.MutationResponse response = client.mutation(operation, params, options);
        return response.parts().withValue(
            Client.decodeEmptyMutation(response.result())
        );
    }

    private static BrowserAttachmentItem decodeAttachment(
        Object value,
        Cursor envelopeCursor
    ) {
        if (envelopeCursor != null) {
            throw new ProtocolError(
                "browser attachment items must not carry a cursor"
            );
        }
        Map<String, Object> fields = Wire.object(value, "browser attachment item");
        String kind = Wire.string(fields.get(Wire.KIND), "browser item kind");
        if (kind.equals("snapshot")) {
            Client.requireExactFields(
                fields,
                "browser snapshot item",
                Wire.KIND,
                Wire.BROWSER,
                "size"
            );
            Map<String, Object> size = Wire.object(
                fields.get("size"),
                "browser pixel size"
            );
            Client.requireExactFields(
                size,
                "browser pixel size",
                "width_px",
                "height_px"
            );
            return new BrowserAttachmentItem.Snapshot(
                Client.decodeBrowser(fields.get(Wire.BROWSER)),
                Client.decodePixelSize(size)
            );
        }
        if (kind.equals("frame")) {
            Client.requireExactFields(
                fields,
                "browser frame item",
                Wire.KIND,
                "mime_type",
                "data_base64",
                "width_px",
                "height_px",
                Wire.POINTER_FRAME_SEQ
            );
            if (!fields.containsKey(Wire.POINTER_FRAME_SEQ)) {
                throw new ProtocolError(
                    "browser frame item omitted required field " +
                        "pointer_frame_seq"
                );
            }
            String mimeType = Wire.string(
                fields.get("mime_type"),
                "browser frame mime_type"
            );
            if (!mimeType.equals("image/png") && !mimeType.equals("image/jpeg")) {
                throw new ProtocolError("browser frame mime_type is invalid");
            }
            byte[] frame = Client.decodeBase64(
                fields.get("data_base64"),
                "browser frame data_base64"
            );
            Map<String, Object> rawDimensions = new LinkedHashMap<>();
            rawDimensions.put("width_px", fields.get("width_px"));
            rawDimensions.put("height_px", fields.get("height_px"));
            Snapshots.PixelSize dimensions =
                Client.decodePixelSize(rawDimensions);
            Optional<Decimal> pointerFrameSeq;
            Object rawPointerFrameSeq = fields.get(Wire.POINTER_FRAME_SEQ);
            if (rawPointerFrameSeq == null) {
                pointerFrameSeq = Optional.empty();
            } else {
                try {
                    pointerFrameSeq = Optional.of(Wire.decimal(
                        rawPointerFrameSeq,
                        "browser frame pointer_frame_seq"
                    ));
                } catch (IllegalArgumentException error) {
                    throw new ProtocolError(
                        "browser frame pointer_frame_seq must be a canonical " +
                            "unsigned decimal string",
                        error
                    );
                }
            }
            return new BrowserAttachmentItem.Frame(
                mimeType,
                frame,
                dimensions.widthPx(),
                dimensions.heightPx(),
                pointerFrameSeq
            );
        }
        if (kind.equals("state")) {
            Client.requireExactFields(
                fields,
                "browser state item",
                Wire.KIND,
                Wire.URL,
                Wire.TITLE,
                "loading"
            );
            return new BrowserAttachmentItem.State(
                Wire.string(fields.get(Wire.URL), "browser state url"),
                Wire.string(fields.get(Wire.TITLE), "browser state title"),
                Wire.bool(fields.get("loading"), "browser state loading")
            );
        }
        return new BrowserAttachmentItem.Unknown(kind, fields);
    }
}
