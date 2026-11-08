package com.cmux;

import com.cmux.internal.Operations;
import com.cmux.internal.Wire;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** Machine resource handle. Copying it performs no I/O. */
public final class Machine {
    private final Client client;
    private final Selector<Ids.MachineId> selector;
    private final Route route;
    private volatile Snapshots.MachineSnapshot snapshot;

    Machine(Client client, Selector<Ids.MachineId> selector) {
        this(client, selector, null);
    }

    Machine(
        Client client,
        Selector<Ids.MachineId> selector,
        Snapshots.MachineSnapshot snapshot
    ) {
        this.client = Objects.requireNonNull(client, "client");
        this.selector = Objects.requireNonNull(selector, "selector");
        this.route = Route.machine(selector);
        this.snapshot = snapshot;
    }

    public Selector<Ids.MachineId> selector() {
        return selector;
    }

    public Optional<Snapshots.MachineSnapshot> cached() {
        return Optional.ofNullable(snapshot);
    }

    public Snapshots.MachineSnapshot refresh() {
        snapshot = Client.decodeMachine(Client.resourcePayload(
            client.request(Operations.MACHINE_GET, route.params(), null),
            Wire.MACHINE
        ));
        return snapshot;
    }

    public Session session(Selector<Ids.SessionId> session) {
        return new Session(client, route.session(session));
    }

    public List<Session> listSessions(Options.Read options) {
        Object result = client.requestValue(
            Operations.SESSION_LIST,
            merge(route.params(), options == null ? Map.of() : options.extra()),
            null
        );
        List<Object> values = Client.listPayload(result, "sessions");
        List<Session> sessions = new ArrayList<>(values.size());
        for (Object value : values) {
            Snapshots.SessionSnapshot decoded = Client.decodeSession(value);
            sessions.add(new Session(
                client,
                route.session(Selector.id(decoded.id())),
                decoded
            ));
        }
        return List.copyOf(sessions);
    }

    public List<Session> findSessionsByName(String name) {
        return listSessions(Options.Read.defaults()).stream()
            .filter(session -> session.cached()
                .flatMap(Snapshots.SessionSnapshot::name)
                .map(name::equals)
                .orElse(false))
            .toList();
    }

    public MutationResult<Session> openSession(
        Selector<Ids.SessionId> session,
        Options.SessionOpen options
    ) {
        Route sessionRoute = route.session(session);
        Client.MutationResponse response = client.mutation(
            Operations.SESSION_OPEN,
            sessionRoute.params(),
            options.mutation()
        );
        Snapshots.SessionSnapshot decoded = Client.decodeSession(
            Client.resourcePayload(response.result(), Wire.SESSION)
        );
        return response.parts().withValue(
            new Session(client, route.session(Selector.id(decoded.id())), decoded)
        );
    }

    private static Map<String, Object> merge(
        Map<String, Object> target,
        Map<String, Object> extra
    ) {
        target.putAll(extra);
        return target;
    }
}
