package com.cmux;

import com.cmux.internal.Operations;
import com.cmux.internal.Wire;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** A sidebar view resource. */
public final class SidebarView {
    private final Client client;
    private final Route route;
    private final Selector<Ids.SidebarViewId> selector;
    private volatile Snapshots.SidebarViewSnapshot snapshot;

    SidebarView(
        Client client,
        Route route,
        Selector<Ids.SidebarViewId> selector
    ) {
        this(client, route, selector, null);
    }

    SidebarView(
        Client client,
        Route route,
        Selector<Ids.SidebarViewId> selector,
        Snapshots.SidebarViewSnapshot snapshot
    ) {
        this.client = Objects.requireNonNull(client, "client");
        this.route = Objects.requireNonNull(route, "route");
        this.selector = Objects.requireNonNull(selector, "selector");
        this.snapshot = snapshot;
    }

    public Optional<Snapshots.SidebarViewSnapshot> cached() {
        return Optional.ofNullable(snapshot);
    }

    public Snapshots.SidebarViewSnapshot refresh() {
        snapshot = Client.decodeSidebarView(Client.resourcePayload(
            client.request(Operations.SIDEBAR_VIEW_GET, params(), null),
            "sidebar_view"
        ));
        return snapshot;
    }

    public ResourceStream<SidebarViewItem> attach(Options.Stream options) {
        Map<String, Object> params = params();
        if (options != null) {
            params.putAll(options.extra());
        }
        return client.openStream(
            Operations.SIDEBAR_VIEW_ATTACH,
            params,
            (value, cursor) -> decodeItem(value, cursor)
        );
    }

    public MutationResult<EmptyResult> input(Options.SidebarInput options) {
        Map<String, Object> params = params();
        params.putAll(options.mutation().extra());
        params.put(
            "data_base64",
            Base64.getEncoder().encodeToString(options.input())
        );
        Client.MutationResponse response = client.mutation(
            Operations.SIDEBAR_VIEW_INPUT, params, options.mutation()
        );
        return response.parts().withValue(
            Client.decodeEmptyMutation(response.result())
        );
    }

    public MutationResult<Snapshots.SidebarViewSnapshot> resize(
        Options.SidebarResize options
    ) {
        Map<String, Object> params = params();
        params.putAll(options.mutation().extra());
        params.put(Wire.COLS, options.columns());
        params.put(Wire.ROWS, options.rows());
        return mutate(Operations.SIDEBAR_VIEW_RESIZE, params, options.mutation());
    }

    public MutationResult<Snapshots.SidebarViewSnapshot> reload(
        Options.Mutation options
    ) {
        Map<String, Object> params = params();
        params.putAll(options.extra());
        return mutate(Operations.SIDEBAR_VIEW_RELOAD, params, options);
    }

    private MutationResult<Snapshots.SidebarViewSnapshot> mutate(
        Operations operation,
        Map<String, Object> params,
        Options.Mutation options
    ) {
        Client.MutationResponse response = client.mutation(operation, params, options);
        snapshot = Client.decodeSidebarView(Client.resourcePayload(
            response.result(), "sidebar_view"
        ));
        return response.parts().withValue(snapshot);
    }

    private Map<String, Object> params() {
        return route.target("sidebar_view", selector);
    }

    private static SidebarViewItem decodeItem(
        Object value,
        Cursor envelopeCursor
    ) {
        if (envelopeCursor != null) {
            throw new ProtocolError(
                "sidebar attachment items must not carry a cursor"
            );
        }
        Map<String, Object> fields = Wire.object(value, "sidebar attachment item");
        String kind = Wire.string(fields.get(Wire.KIND), "sidebar item kind");
        if (kind.equals("snapshot")) {
            Client.requireExactFields(
                fields,
                "sidebar snapshot item",
                Wire.KIND,
                "sidebar_view",
                "render"
            );
            return new SidebarViewItem.Snapshot(
                Client.decodeSidebarView(fields.get("sidebar_view")),
                Client.decodeRenderSnapshot(fields.get("render"))
            );
        }
        if (kind.equals("patch")) {
            Client.requireExactFields(
                fields,
                "sidebar patch item",
                Wire.KIND,
                "sidebar_view_id",
                "render"
            );
            return new SidebarViewItem.Patch(
                new Ids.SidebarViewId(Wire.string(
                    fields.get("sidebar_view_id"),
                    "sidebar view id"
                )),
                Client.decodeRenderPatch(fields.get("render"))
            );
        }
        if (kind.equals("scroll")) {
            Client.requireExactFields(
                fields,
                "sidebar scroll item",
                Wire.KIND,
                "sidebar_view_id",
                "scroll"
            );
            return new SidebarViewItem.Scroll(
                new Ids.SidebarViewId(Wire.string(
                    fields.get("sidebar_view_id"),
                    "sidebar view id"
                )),
                Client.decodeRenderScroll(fields.get("scroll"))
            );
        }
        return new SidebarViewItem.Unknown(kind, fields);
    }
}
