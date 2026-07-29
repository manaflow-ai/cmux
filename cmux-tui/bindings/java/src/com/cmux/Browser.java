package com.cmux;

import com.cmux.internal.Operations;
import com.cmux.internal.Wire;
import java.util.Base64;
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

    public MutationResult<EmptyResult> mouse(Options.Mouse options) {
        Map<String, Object> params = mutationParams(options.mutation());
        params.putAll(options.mouse());
        return emptyMutation(
            Operations.BROWSER_INPUT_MOUSE, params, options.mutation()
        );
    }

    public MutationResult<EmptyResult> wheel(Options.Wheel options) {
        Map<String, Object> params = mutationParams(options.mutation());
        params.put("delta_x", options.deltaX());
        params.put("delta_y", options.deltaY());
        options.x().ifPresent(value -> params.put("x_px", value));
        options.y().ifPresent(value -> params.put("y_px", value));
        return emptyMutation(
            Operations.BROWSER_INPUT_WHEEL, params, options.mutation()
        );
    }

    public Document resizeViewer(Options.ViewerSize options) {
        Map<String, Object> params = params();
        params.putAll(options.control().extra());
        params.put("width_px", options.width());
        params.put("height_px", options.height());
        return Client.document(client.request(
            Operations.BROWSER_VIEWER_RESIZE, params, null
        ));
    }

    public Document releaseViewer(Options.Control options) {
        Map<String, Object> params = params();
        if (options != null) {
            params.putAll(options.extra());
        }
        return Client.document(client.request(
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
            Operations.BROWSER_ATTACH, params, Browser::decodeAttachment
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

    private static BrowserAttachmentItem decodeAttachment(Object value) {
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
            return new BrowserAttachmentItem(
                kind,
                Optional.of(Client.decodeBrowser(fields.get(Wire.BROWSER))),
                Optional.of(new Snapshots.PixelSize(
                    Client.integer(size, "width_px"),
                    Client.integer(size, "height_px")
                )),
                Optional.empty(),
                Optional.empty(),
                Optional.empty(),
                Optional.empty(),
                new byte[0],
                Optional.empty(),
                Optional.empty(),
                Map.of()
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
                "height_px"
            );
            String mimeType = Wire.string(
                fields.get("mime_type"),
                "browser frame mime_type"
            );
            if (!mimeType.equals("image/png") && !mimeType.equals("image/jpeg")) {
                throw new ProtocolError("browser frame mime_type is invalid");
            }
            byte[] frame;
            try {
                frame = Base64.getDecoder().decode(Wire.string(
                    fields.get("data_base64"),
                    "browser frame data_base64"
                ));
            } catch (IllegalArgumentException error) {
                throw new ProtocolError(
                    "browser frame data_base64 is invalid",
                    error
                );
            }
            int width = Client.integer(fields, "width_px");
            int height = Client.integer(fields, "height_px");
            if (width <= 0 || height <= 0) {
                throw new ProtocolError(
                    "browser frame dimensions must be positive"
                );
            }
            return new BrowserAttachmentItem(
                kind,
                Optional.empty(),
                Optional.empty(),
                Optional.empty(),
                Optional.empty(),
                Optional.empty(),
                Optional.of(mimeType),
                frame,
                Optional.of(width),
                Optional.of(height),
                Map.of()
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
            return new BrowserAttachmentItem(
                kind,
                Optional.empty(),
                Optional.empty(),
                Optional.of(Wire.string(fields.get(Wire.URL), "browser state url")),
                Optional.of(Wire.string(
                    fields.get(Wire.TITLE),
                    "browser state title"
                )),
                Optional.of(Wire.bool(
                    fields.get("loading"),
                    "browser state loading"
                )),
                Optional.empty(),
                new byte[0],
                Optional.empty(),
                Optional.empty(),
                Map.of()
            );
        }
        return new BrowserAttachmentItem(
            kind,
            Optional.empty(),
            Optional.empty(),
            Optional.empty(),
            Optional.empty(),
            Optional.empty(),
            Optional.empty(),
            new byte[0],
            Optional.empty(),
            Optional.empty(),
            fields
        );
    }
}
