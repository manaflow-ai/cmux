package com.cmux;

import com.cmux.internal.Operations;
import com.cmux.internal.Wire;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** Provider scope handle rooted at the current machine. */
public final class ProviderScope {
    private final Client client;
    private final Selector<Ids.MachineId> machine;
    private final Selector<Ids.ProviderScopeId> selector;
    private volatile Snapshots.ProviderScopeSnapshot snapshot;

    ProviderScope(Client client, Selector<Ids.ProviderScopeId> selector) {
        this(client, Selector.current(), selector, null);
    }

    ProviderScope(
        Client client,
        Selector<Ids.MachineId> machine,
        Selector<Ids.ProviderScopeId> selector,
        Snapshots.ProviderScopeSnapshot snapshot
    ) {
        this.client = Objects.requireNonNull(client, "client");
        this.machine = Objects.requireNonNull(machine, "machine");
        this.selector = Objects.requireNonNull(selector, "selector");
        this.snapshot = snapshot;
    }

    public Optional<Snapshots.ProviderScopeSnapshot> cached() {
        return Optional.ofNullable(snapshot);
    }

    public MutationResult<Machine> createMachine(Options.MachineCreate options) {
        Objects.requireNonNull(options, "options");
        Map<String, Object> params = providerOnlyParams();
        params.putAll(options.mutation().extra());
        Client.MutationResponse response = client.mutation(
            Operations.MACHINE_CREATE,
            params,
            options.mutation()
        );
        Snapshots.MachineSnapshot decoded = Client.decodeMachine(
            Client.resourcePayload(response.result(), Wire.MACHINE)
        );
        return response.parts().withValue(
            new Machine(client, Selector.id(decoded.id()), decoded)
        );
    }

    public MutationResult<Machine> connectExternalMachine(
        Options.MachineConnectExternal options
    ) {
        Objects.requireNonNull(options, "options");
        Map<String, Object> params = providerOnlyParams();
        params.putAll(options.mutation().extra());
        params.put("specifier", options.specifier().reveal());
        Client.MutationResponse response = client.mutation(
            Operations.MACHINE_CONNECT_EXTERNAL,
            params,
            options.mutation()
        );
        Snapshots.MachineSnapshot decoded = Client.decodeMachine(
            Client.resourcePayload(response.result(), Wire.MACHINE)
        );
        return response.parts().withValue(
            new Machine(client, Selector.id(decoded.id()), decoded)
        );
    }

    public List<ProviderAction> actions() {
        Snapshots.ProviderScopeSnapshot current = snapshot;
        if (current == null) {
            throw new IllegalStateException(
                "provider actions are available from a listed provider scope snapshot"
            );
        }
        Object raw = current.extra().get("actions");
        if (!(raw instanceof List<?> values)) {
            return List.of();
        }
        List<ProviderAction> actions = new ArrayList<>();
        for (Object value : values) {
            Snapshots.ProviderActionSnapshot action = Client.decodeProviderAction(value);
            Map<String, Object> params = params();
            params.put("provider_action", Selector.id(action.id()));
            actions.add(new ProviderAction(client, params, action));
        }
        return List.copyOf(actions);
    }

    public ProviderAction action(Selector<Ids.ProviderActionId> action) {
        Map<String, Object> selectors = params();
        selectors.put("provider_action", Objects.requireNonNull(action, "action"));
        return new ProviderAction(client, selectors, null);
    }

    public ResourceStream<ProviderNoticeItem> notices(Options.ProviderNotices options) {
        Map<String, Object> params = params();
        params.putAll(options.stream().extra());
        options.cursor().ifPresent(cursor -> params.put(
            Wire.CURSOR,
            Map.of(
                Wire.GENERATION, cursor.generation(),
                Wire.REVISION, cursor.revision()
            )
        ));
        return client.openStream(
            Operations.PROVIDER_NOTICE_EVENTS,
            params,
            (value, cursor) -> {
                if (cursor == null) {
                    throw new ProtocolError(
                        "provider notice items require an envelope cursor"
                    );
                }
                return decodeNotice(value);
            }
        );
    }

    public MutationResult<Snapshots.WorkspaceSnapshot> markWorkspace(
        Selector<Ids.SessionId> session,
        Options.ProviderWorkspace options
    ) {
        Map<String, Object> params = workspaceParams(session, options.workspace());
        params.putAll(options.mutation().extra());
        params.put("managed", options.managed());
        return workspaceMutation(
            Operations.PROVIDER_WORKSPACE_MARK, params, options.mutation()
        );
    }

    public MutationResult<Snapshots.WorkspaceSnapshot> renameWorkspace(
        Selector<Ids.SessionId> session,
        Options.ProviderWorkspaceRename options
    ) {
        Map<String, Object> params = workspaceParams(session, options.workspace());
        params.putAll(options.mutation().extra());
        params.put(Wire.NAME, options.name().toWire());
        return workspaceMutation(
            Operations.PROVIDER_WORKSPACE_RENAME, params, options.mutation()
        );
    }

    public MutationResult<EmptyResult> closeWorkspace(
        Selector<Ids.SessionId> session,
        Options.ProviderWorkspaceClose options
    ) {
        Map<String, Object> params = workspaceParams(session, options.workspace());
        params.putAll(options.mutation().extra());
        Client.MutationResponse response = client.mutation(
            Operations.PROVIDER_WORKSPACE_CLOSE, params, options.mutation()
        );
        return response.parts().withValue(
            Client.decodeEmptyMutation(response.result())
        );
    }

    private MutationResult<Snapshots.WorkspaceSnapshot> workspaceMutation(
        Operations operation,
        Map<String, Object> params,
        Options.Mutation options
    ) {
        Client.MutationResponse response = client.mutation(operation, params, options);
        Snapshots.WorkspaceSnapshot workspace = Client.decodeWorkspace(
            Client.resourcePayload(response.result(), Wire.WORKSPACE)
        );
        return response.parts().withValue(workspace);
    }

    private Map<String, Object> workspaceParams(
        Selector<Ids.SessionId> session,
        Selector<Ids.WorkspaceId> workspace
    ) {
        Map<String, Object> params = params();
        params.put(Wire.SESSION, session);
        params.put(Wire.WORKSPACE, workspace);
        return params;
    }

    private Map<String, Object> params() {
        return Client.selectors(
            Wire.MACHINE, machine,
            "provider_scope", selector
        );
    }

    private Map<String, Object> providerOnlyParams() {
        return Client.selectors("provider_scope", selector);
    }

    private ProviderNoticeItem decodeNotice(Object value) {
        Map<String, Object> fields = Wire.object(value, "provider notice item");
        String kind = Wire.string(fields.get(Wire.KIND), "provider notice kind");
        if (!kind.equals("notice")) {
            return new ProviderNoticeItem.Unknown(kind, fields);
        }
        Client.requireExactFields(
            fields,
            "provider notice item",
            Wire.KIND,
            "notice",
            "sequence"
        );
        Decimal sequence = Wire.decimal(
            fields.get("sequence"),
            "provider notice sequence"
        );
        ProviderNotice notice = new ProviderNotice(
            client,
            machine,
            selector,
            Client.decodeProviderNotice(fields.get("notice")),
            sequence
        );
        return new ProviderNoticeItem.Known(notice, sequence);
    }
}
