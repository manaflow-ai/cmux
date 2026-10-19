package com.cmux;

import com.cmux.internal.Operations;
import com.cmux.internal.Wire;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

public final class Pane {
    private final Client client;
    private final Route route;
    private volatile Snapshots.PaneSnapshot snapshot;

    Pane(Client client, Route route) {
        this(client, route, null);
    }

    Pane(Client client, Route route, Snapshots.PaneSnapshot snapshot) {
        this.client = Objects.requireNonNull(client, "client");
        this.route = Objects.requireNonNull(route, "route");
        this.snapshot = snapshot;
    }

    public Optional<Snapshots.PaneSnapshot> cached() {
        return Optional.ofNullable(snapshot);
    }

    public Snapshots.PaneSnapshot refresh() {
        snapshot = Client.decodePane(Client.resourcePayload(
            client.request(Operations.PANE_GET, route.params(), null),
            Wire.PANE
        ));
        return snapshot;
    }

    public MutationResult<CreatedTerminalPath> split(Options.PaneSplit options) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        params.put(Wire.DIRECTION, options.direction().toWire());
        options.ratio().ifPresent(value -> params.put(Wire.RATIO, value));
        options.viewportWidth().ifPresent(
            value -> params.put(Wire.VIEWPORT_WIDTH, value)
        );
        options.cwd().ifPresent(value -> params.put(Wire.CWD, value));
        options.columns().ifPresent(value -> params.put(Wire.COLS, value));
        options.rows().ifPresent(value -> params.put(Wire.ROWS, value));
        options.correlationKey().ifPresent(
            key -> params.put("correlation_key", key)
        );
        Client.MutationResponse response = client.mutation(
            Operations.PANE_SPLIT, params, options.mutation()
        );
        return response.parts().withValue(
            Client.decodeCreatedTerminalPath(response.result())
        );
    }

    public MutationResult<Snapshots.PaneSnapshot> rename(Options.PaneRename options) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        params.put(Wire.NAME, options.name());
        return mutateSnapshot(Operations.PANE_RENAME, params, options.mutation());
    }

    public MutationResult<Snapshots.PaneSnapshot> focus(Options.Mutation options) {
        return mutateSnapshot(
            Operations.PANE_FOCUS,
            withExtra(route.params(), options.extra()),
            options
        );
    }

    public MutationResult<Snapshots.PaneSnapshot> focusDirection(
        Options.DirectionInput options
    ) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        params.put(Wire.DIRECTION, options.direction().toWire());
        return mutateSnapshot(
            Operations.PANE_FOCUS_DIRECTION, params, options.mutation()
        );
    }

    public Results.PaneNeighborResult neighbor(Options.DirectionRead options) {
        Map<String, Object> params = withExtra(route.params(), options.read().extra());
        params.put(Wire.DIRECTION, options.direction().toWire());
        return Client.decodePaneNeighbor(client.requestValue(
            Operations.PANE_NEIGHBOR_GET,
            params,
            null
        ));
    }

    public MutationResult<Snapshots.PaneSnapshot> swap(Options.PaneSwap options) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        params.put("other_workspace", options.workspace());
        params.put("other_screen", options.screen());
        params.put("other_pane", options.pane());
        return mutateSnapshot(Operations.PANE_SWAP, params, options.mutation());
    }

    public MutationResult<Snapshots.PaneSnapshot> zoom(Options.PaneZoom options) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        options.enabled().ifPresent(value -> params.put(Wire.ENABLED, value));
        return mutateSnapshot(Operations.PANE_ZOOM, params, options.mutation());
    }

    public MutationResult<Snapshots.PaneSnapshot> setSplitRatio(Options.Ratio options) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        params.put("split_id", options.splitId());
        params.put(Wire.RATIO, options.ratio());
        return mutateSnapshot(
            Operations.PANE_SPLIT_RATIO_SET, params, options.mutation()
        );
    }

    public MutationResult<Snapshots.PaneSnapshot> setViewportWidth(
        Options.Width options
    ) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        params.put("columns", options.width());
        return mutateSnapshot(
            Operations.PANE_VIEWPORT_WIDTH_SET, params, options.mutation()
        );
    }

    public MutationResult<EmptyResult> close(Options.Mutation options) {
        Client.MutationResponse response = client.mutation(
            Operations.PANE_CLOSE,
            withExtra(route.params(), options.extra()),
            options
        );
        return response.parts().withValue(
            Client.decodeEmptyMutation(response.result())
        );
    }

    public MutationResult<CreatedTerminalPath> run(Options.Run options) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        Client.command(params, options.command());
        options.cwd().ifPresent(value -> params.put(Wire.CWD, value));
        options.name().ifPresent(value -> params.put(Wire.NAME, value));
        options.columns().ifPresent(value -> params.put(Wire.COLS, value));
        options.rows().ifPresent(value -> params.put(Wire.ROWS, value));
        options.correlationKey().ifPresent(
            key -> params.put("correlation_key", key)
        );
        Client.MutationResponse response = client.mutation(
            Operations.PANE_RUN, params, options.mutation()
        );
        return response.parts().withValue(
            Client.decodeCreatedTerminalPath(response.result())
        );
    }

    public Tab tab(Selector<Ids.TabId> selector) {
        return new Tab(client, route.tab(selector));
    }

    public List<Tab> listTabs(Options.Read options) {
        Object result = client.requestValue(
            Operations.TAB_LIST,
            withExtra(route.params(), options == null ? Map.of() : options.extra()),
            null
        );
        List<Tab> tabs = new ArrayList<>();
        for (Object value : Client.listPayload(result, "tabs")) {
            Snapshots.TabSnapshot decoded = Client.decodeTab(value);
            tabs.add(new Tab(client, route.tab(Selector.id(decoded.id())), decoded));
        }
        return List.copyOf(tabs);
    }

    public List<Tab> findTabsByName(String name) {
        return listTabs(Options.Read.defaults()).stream()
            .filter(tab -> tab.cached().flatMap(Snapshots.TabSnapshot::name)
                .map(name::equals).orElse(false))
            .toList();
    }

    public MutationResult<CreatedTerminalPath> createTerminalTab(
        Options.TabCreateTerminal options
    ) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        options.name().ifPresent(value -> params.put(Wire.NAME, value));
        options.cwd().ifPresent(value -> params.put(Wire.CWD, value));
        options.columns().ifPresent(value -> params.put(Wire.COLS, value));
        options.rows().ifPresent(value -> params.put(Wire.ROWS, value));
        options.correlationKey().ifPresent(
            key -> params.put("correlation_key", key)
        );
        Client.MutationResponse response = client.mutation(
            Operations.TAB_CREATE_TERMINAL, params, options.mutation()
        );
        return response.parts().withValue(
            Client.decodeCreatedTerminalPath(response.result())
        );
    }

    public MutationResult<CreatedBrowserPath> createBrowserTab(
        Options.TabCreateBrowser options
    ) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        params.put(Wire.URL, options.url());
        options.name().ifPresent(value -> params.put(Wire.NAME, value));
        options.width().ifPresent(value -> params.put("width_px", value));
        options.height().ifPresent(value -> params.put("height_px", value));
        options.correlationKey().ifPresent(
            key -> params.put("correlation_key", key)
        );
        Client.MutationResponse response = client.mutation(
            Operations.TAB_CREATE_BROWSER, params, options.mutation()
        );
        return response.parts().withValue(
            Client.decodeCreatedBrowserPath(response.result())
        );
    }

    private MutationResult<Snapshots.PaneSnapshot> mutateSnapshot(
        Operations operation,
        Map<String, Object> params,
        Options.Mutation options
    ) {
        Client.MutationResponse response = client.mutation(operation, params, options);
        snapshot = Client.decodePane(
            Client.resourcePayload(response.result(), Wire.PANE)
        );
        return response.parts().withValue(snapshot);
    }

    private static Map<String, Object> withExtra(
        Map<String, Object> params,
        Map<String, Object> extra
    ) {
        params.putAll(extra);
        return params;
    }
}
