package com.cmux;

import com.cmux.internal.Operations;
import com.cmux.internal.Wire;
import java.util.Map;
import java.util.Objects;

/** Provider notice handle. Delivery never acknowledges it automatically. */
public final class ProviderNotice {
    private final Client client;
    private final Selector<Ids.MachineId> machine;
    private final Selector<Ids.ProviderScopeId> scope;
    private final Selector<Ids.ProviderNoticeId> selector;
    private final Snapshots.ProviderNoticeSnapshot snapshot;
    private final Decimal sequence;

    ProviderNotice(
        Client client,
        Selector<Ids.MachineId> machine,
        Selector<Ids.ProviderScopeId> scope,
        Snapshots.ProviderNoticeSnapshot snapshot,
        Decimal sequence
    ) {
        this.client = Objects.requireNonNull(client, "client");
        this.machine = Objects.requireNonNull(machine, "machine");
        this.scope = Objects.requireNonNull(scope, "scope");
        this.snapshot = Objects.requireNonNull(snapshot, "snapshot");
        this.selector = Selector.id(snapshot.id());
        this.sequence = Objects.requireNonNull(sequence, "sequence");
    }

    public Snapshots.ProviderNoticeSnapshot snapshot() {
        return snapshot;
    }

    public Decimal sequence() {
        return sequence;
    }

    public EmptyResult acknowledge() {
        Map<String, Object> params = Client.selectors(
            Wire.MACHINE,
            machine,
            "provider_scope",
            scope,
            "provider_notice",
            selector
        );
        params.put("sequence", sequence);
        Map<String, Object> result = client.request(
            Operations.PROVIDER_NOTICE_ACKNOWLEDGE,
            params,
            null
        );
        Client.requireExactFields(result, "provider notice acknowledge result");
        return new EmptyResult();
    }

    public Map<String, Object> extra() {
        return snapshot.extra();
    }
}
