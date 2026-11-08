package com.cmux;

import com.cmux.internal.Operations;
import com.cmux.internal.Wire;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

public final class Workspace {
    private final Client client;
    private final Route route;
    private volatile Snapshots.WorkspaceSnapshot snapshot;

    Workspace(Client client, Route route) {
        this(client, route, null);
    }

    Workspace(Client client, Route route, Snapshots.WorkspaceSnapshot snapshot) {
        this.client = Objects.requireNonNull(client, "client");
        this.route = Objects.requireNonNull(route, "route");
        this.snapshot = snapshot;
    }

    public Optional<Snapshots.WorkspaceSnapshot> cached() {
        return Optional.ofNullable(snapshot);
    }

    public Snapshots.WorkspaceSnapshot refresh() {
        snapshot = Client.decodeWorkspace(Client.resourcePayload(
            client.request(Operations.WORKSPACE_GET, route.params(), null),
            Wire.WORKSPACE
        ));
        return snapshot;
    }

    public MutationResult<Snapshots.WorkspaceSnapshot> rename(
        Options.WorkspaceRename options
    ) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        params.put(Wire.NAME, options.name());
        return snapshotMutation(Operations.WORKSPACE_RENAME, params, options.mutation());
    }

    public MutationResult<Snapshots.WorkspaceSnapshot> move(
        Options.WorkspaceMove options
    ) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        params.put("index", options.index());
        return snapshotMutation(Operations.WORKSPACE_MOVE, params, options.mutation());
    }

    public MutationResult<Snapshots.WorkspaceSnapshot> focus(Options.Mutation options) {
        return snapshotMutation(
            Operations.WORKSPACE_FOCUS,
            withExtra(route.params(), options.extra()),
            options
        );
    }

    public MutationResult<EmptyResult> close(Options.Mutation options) {
        Client.MutationResponse response = client.mutation(
            Operations.WORKSPACE_CLOSE,
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
            Operations.WORKSPACE_RUN, params, options.mutation()
        );
        return response.parts().withValue(
            Client.decodeCreatedTerminalPath(response.result())
        );
    }

    public MutationResult<Snapshots.WorkspaceSnapshot> applyLayout(
        Options.LayoutApply options
    ) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        params.put(Wire.LAYOUT, options.layout());
        return snapshotMutation(
            Operations.WORKSPACE_LAYOUT_APPLY, params, options.mutation()
        );
    }

    public Screen screen(Selector<Ids.ScreenId> selector) {
        return new Screen(client, route.screen(selector));
    }

    public List<Screen> listScreens(Options.Read options) {
        Object result = client.requestValue(
            Operations.SCREEN_LIST,
            withExtra(route.params(), options == null ? Map.of() : options.extra()),
            null
        );
        List<Screen> screens = new ArrayList<>();
        for (Object value : Client.listPayload(result, "screens")) {
            Snapshots.ScreenSnapshot decoded = Client.decodeScreen(value);
            screens.add(new Screen(
                client,
                route.screen(Selector.id(decoded.id())),
                decoded
            ));
        }
        return List.copyOf(screens);
    }

    public List<Screen> findScreensByName(String name) {
        return listScreens(Options.Read.defaults()).stream()
            .filter(screen -> screen.cached().flatMap(Snapshots.ScreenSnapshot::name)
                .map(name::equals).orElse(false))
            .toList();
    }

    public MutationResult<CreatedTerminalPath> createScreen(
        Options.ScreenCreate options
    ) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        options.name().ifPresent(value -> params.put(Wire.NAME, value));
        options.correlationKey().ifPresent(
            key -> params.put("correlation_key", key)
        );
        Client.MutationResponse response = client.mutation(
            Operations.SCREEN_CREATE, params, options.mutation()
        );
        return response.parts().withValue(
            Client.decodeCreatedTerminalPath(response.result())
        );
    }

    private MutationResult<Snapshots.WorkspaceSnapshot> snapshotMutation(
        Operations operation,
        Map<String, Object> params,
        Options.Mutation options
    ) {
        Client.MutationResponse response = client.mutation(operation, params, options);
        snapshot = Client.decodeWorkspace(
            Client.resourcePayload(response.result(), Wire.WORKSPACE)
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
