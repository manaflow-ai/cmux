package com.cmux;

import com.cmux.internal.Operations;
import com.cmux.internal.Wire;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** A connected client resource. The handle does not own the remote client. */
public final class ConnectedClient {
    private final Client client;
    private final Route route;
    private final Selector<Ids.ConnectedClientId> selector;
    private volatile Snapshots.ConnectedClientSnapshot snapshot;

    ConnectedClient(
        Client client,
        Route route,
        Selector<Ids.ConnectedClientId> selector
    ) {
        this(client, route, selector, null);
    }

    ConnectedClient(
        Client client,
        Route route,
        Selector<Ids.ConnectedClientId> selector,
        Snapshots.ConnectedClientSnapshot snapshot
    ) {
        this.client = Objects.requireNonNull(client, "client");
        this.route = Objects.requireNonNull(route, "route");
        this.selector = Objects.requireNonNull(selector, "selector");
        this.snapshot = snapshot;
    }

    public Optional<Snapshots.ConnectedClientSnapshot> cached() {
        return Optional.ofNullable(snapshot);
    }

    public Snapshots.ConnectedClientSnapshot refresh() {
        snapshot = Client.decodeConnectedClient(Client.resourcePayload(
            client.request(Operations.CLIENT_GET, params(), null),
            Wire.CLIENT
        ));
        return snapshot;
    }

    public Snapshots.ConnectedClientSnapshot updateMetadata(
        Options.ClientMetadata options
    ) {
        Map<String, Object> params = withExtra(params(), options.control().extra());
        if (options.name().present()) {
            params.put(Wire.NAME, options.name().toWire());
        }
        if (options.kind().present()) {
            params.put(Wire.KIND, options.kind().toWire());
        }
        snapshot = Client.decodeConnectedClient(Client.resourcePayload(
            client.request(Operations.CLIENT_METADATA_UPDATE, params, null),
            Wire.CLIENT
        ));
        return snapshot;
    }

    public Snapshots.ConnectedClientSnapshot setSizing(Options.ClientSizing options) {
        Map<String, Object> params = withExtra(params(), options.control().extra());
        params.put(Wire.ENABLED, options.enabled());
        options.exclusive().ifPresent(value -> params.put("exclusive", value));
        snapshot = Client.decodeConnectedClient(Client.resourcePayload(
            client.request(Operations.CLIENT_SIZING_SET, params, null),
            Wire.CLIENT
        ));
        return snapshot;
    }

    public Snapshots.ConnectedClientSnapshot releaseSizing(Options.Control options) {
        snapshot = Client.decodeConnectedClient(Client.resourcePayload(
            client.request(
                Operations.CLIENT_SIZING_RELEASE,
                withExtra(params(), options == null ? Map.of() : options.extra()),
                null
            ),
            Wire.CLIENT
        ));
        return snapshot;
    }

    public Document setCellPixels(Options.CellPixels options) {
        Map<String, Object> params = withExtra(params(), options.control().extra());
        params.put("width_px", options.width());
        params.put("height_px", options.height());
        return Client.document(client.request(
            Operations.CLIENT_CELL_PIXELS_SET, params, null
        ));
    }

    public Document detach(Options.Control options) {
        return Client.document(client.request(
            Operations.CLIENT_DETACH,
            withExtra(params(), options == null ? Map.of() : options.extra()),
            null
        ));
    }

    private Map<String, Object> params() {
        return route.target(Wire.CLIENT, selector);
    }

    private static Map<String, Object> withExtra(
        Map<String, Object> params,
        Map<String, Object> extra
    ) {
        params.putAll(extra);
        return params;
    }
}
