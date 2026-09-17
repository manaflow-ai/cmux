package com.cmux;

import com.cmux.internal.Operations;
import com.cmux.internal.Wire;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** Session resource handle. It does not own or close its server resource. */
public final class Session {
    private final Client client;
    private final Route route;
    private volatile Snapshots.SessionSnapshot snapshot;

    Session(Client client, Route route) {
        this(client, route, null);
    }

    Session(Client client, Route route, Snapshots.SessionSnapshot snapshot) {
        this.client = Objects.requireNonNull(client, "client");
        this.route = Objects.requireNonNull(route, "route");
        this.snapshot = snapshot;
    }

    public Optional<Snapshots.SessionSnapshot> cached() {
        return Optional.ofNullable(snapshot);
    }

    public Snapshots.SessionSnapshot refresh() {
        snapshot = Client.decodeSession(Client.resourcePayload(
            client.request(Operations.SESSION_GET, route.params(), null),
            Wire.SESSION
        ));
        return snapshot;
    }

    public ResourceSnapshot snapshot(Options.Read options) {
        Map<String, Object> params = withExtra(route.params(), options);
        return Client.decodeResourceSnapshot(
            client.requestValue(Operations.SESSION_SNAPSHOT, params, null)
        );
    }

    public Results.CreationResolution resolveCreation(
        Options.CreationResolve options
    ) {
        Map<String, Object> params = withExtra(
            route.params(),
            options.read().extra()
        );
        params.put("correlation_key", options.correlationKey());
        return Client.decodeCreationResolution(client.requestValue(
            Operations.SESSION_CREATION_RESOLVE,
            params,
            null
        ));
    }

    public ResourceStream<SessionEvent> events(Options.SessionEvents options) {
        Map<String, Object> params = withExtra(route.params(), options.stream().extra());
        options.cursor().ifPresent(cursor -> params.put(Wire.CURSOR, cursorMap(cursor)));
        return client.openStream(Operations.SESSION_EVENTS, params, Session::decodeEvent);
    }

    public ResourceStream<SessionJournalRecord> journal(Options.SessionJournal options) {
        Map<String, Object> params = withExtra(route.params(), options.stream().extra());
        options.cursor().ifPresent(cursor -> params.put(Wire.CURSOR, cursorMap(cursor)));
        options.start().ifPresent(start -> params.put(Wire.START, start.toWire()));
        options.follow().ifPresent(follow -> params.put("follow", follow));
        options.filter().ifPresent(filter -> {
            Map<String, Object> encoded = Wire.map();
            if (!filter.kinds().isEmpty()) encoded.put("kinds", filter.kinds());
            if (!filter.classes().isEmpty()) {
                encoded.put(
                    "classes",
                    filter.classes().stream()
                        .map(value -> value.name().toLowerCase(java.util.Locale.ROOT))
                        .toList()
                );
            }
            if (!filter.subjects().isEmpty()) {
                encoded.put("subjects", filter.subjects().stream().map(subject -> {
                    Map<String, Object> value = Wire.map();
                    subject.kind().ifPresent(kind -> value.put("kind", kind));
                    subject.id().ifPresent(id -> value.put("id", id));
                    if (value.isEmpty()) {
                        throw new IllegalArgumentException(
                            "journal subject filter requires kind or id"
                        );
                    }
                    return value;
                }).toList());
            }
            filter.maxSensitivity().ifPresent(value -> encoded.put(
                "max_sensitivity",
                value.name().toLowerCase(java.util.Locale.ROOT)
            ));
            filter.regex().ifPresent(regex -> encoded.put("regex", Map.of(
                "pattern", regex.pattern(),
                "field", regex.field().toWire(),
                "case_sensitive", regex.caseSensitive()
            )));
            if (!encoded.isEmpty()) params.put("filter", encoded);
        });
        return client.openStream(
            Operations.SESSION_JOURNAL_SUBSCRIBE,
            params,
            Session::decodeJournalRecord
        );
    }

    public Results.PingResult ping(Options.Read options) {
        return Client.decodePingResult(client.requestValue(
            Operations.SESSION_PING,
            withExtra(route.params(), options),
            null
        ));
    }

    public MutationResult<Results.ShutdownResult> shutdown(
        Options.SessionShutdown options
    ) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        if (options.force()) {
            params.put(Wire.FORCE, true);
        }
        Client.MutationResponse response = client.mutation(
            Operations.SESSION_SHUTDOWN, params, options.mutation()
        );
        return response.parts().withValue(Client.decodeShutdownResult(
            response.result().get(Wire.VALUE)
        ));
    }

    public MutationResult<Results.ReloadConfigResult> reloadConfig(
        Options.Mutation options
    ) {
        Client.MutationResponse response = client.mutation(
            Operations.SESSION_RELOAD_CONFIG,
            withExtra(route.params(), options.extra()),
            options
        );
        return response.parts().withValue(Client.decodeReloadConfigResult(
            response.result().get(Wire.VALUE)
        ));
    }

    public MutationResult<Results.TerminalDefaultsSnapshot> updateTerminalDefaults(
        Options.TerminalDefaults options
    ) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        params.putAll(options.defaults());
        Client.MutationResponse response = client.mutation(
            Operations.SESSION_TERMINAL_DEFAULTS_UPDATE,
            params,
            options.mutation()
        );
        return response.parts().withValue(Client.decodeTerminalDefaults(
            response.result().get(Wire.VALUE)
        ));
    }

    public MutationResult<EmptyResult> setWindowTitle(Options.WindowTitle options) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        params.put(Wire.TITLE, options.title());
        Client.MutationResponse response = client.mutation(
            Operations.SESSION_WINDOW_TITLE_SET, params, options.mutation()
        );
        return response.parts().withValue(
            Client.decodeEmptyMutation(response.result())
        );
    }

    public MutationResult<EmptyResult> clearWindowTitle(Options.Mutation options) {
        Client.MutationResponse response = client.mutation(
            Operations.SESSION_WINDOW_TITLE_CLEAR,
            withExtra(route.params(), options.extra()),
            options
        );
        return response.parts().withValue(
            Client.decodeEmptyMutation(response.result())
        );
    }

    public Workspace workspace(Selector<Ids.WorkspaceId> selector) {
        return new Workspace(client, route.workspace(selector));
    }

    public List<Workspace> listWorkspaces(Options.Read options) {
        Object result = client.requestValue(
            Operations.WORKSPACE_LIST,
            withExtra(route.params(), options),
            null
        );
        List<Object> values = Client.listPayload(result, "workspaces");
        List<Workspace> workspaces = new ArrayList<>(values.size());
        for (Object value : values) {
            Snapshots.WorkspaceSnapshot decoded = Client.decodeWorkspace(value);
            workspaces.add(new Workspace(
                client,
                route.workspace(Selector.id(decoded.id())),
                decoded
            ));
        }
        return List.copyOf(workspaces);
    }

    public List<Workspace> findWorkspacesByName(String name) {
        return listWorkspaces(Options.Read.defaults()).stream()
            .filter(workspace -> workspace.cached()
                .map(Snapshots.WorkspaceSnapshot::name)
                .map(name::equals)
                .orElse(false))
            .toList();
    }

    public MutationResult<CreatedPath> createWorkspace(
        Options.WorkspaceCreate options
    ) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        options.name().ifPresent(name -> params.put(Wire.NAME, name));
        params.put(Wire.INITIAL_CONTENT, options.initialContent().toWire());
        options.correlationKey().ifPresent(
            key -> params.put("correlation_key", key)
        );
        Client.MutationResponse response = client.mutation(
            Operations.WORKSPACE_CREATE, params, options.mutation()
        );
        return response.parts().withValue(Client.decodeCreatedPath(response.result()));
    }

    public ConnectedClient connectedClient(Selector<Ids.ConnectedClientId> selector) {
        return new ConnectedClient(client, route, selector);
    }

    public List<ConnectedClient> listConnectedClients(Options.Read options) {
        Object result = client.requestValue(
            Operations.CLIENT_LIST,
            withExtra(route.params(), options),
            null
        );
        List<Object> values = Client.listPayload(result, "clients");
        List<ConnectedClient> clients = new ArrayList<>(values.size());
        for (Object value : values) {
            Snapshots.ClientSnapshot decoded = Client.decodeConnectedClient(value);
            clients.add(new ConnectedClient(
                client, route, Selector.id(decoded.id()), decoded
            ));
        }
        return List.copyOf(clients);
    }

    public List<PairingRequest> listPairingRequests(Options.Read options) {
        Object result = client.requestValue(
            Operations.PAIRING_REQUEST_LIST,
            withExtra(route.params(), options),
            null
        );
        List<PairingRequest> requests = new ArrayList<>();
        for (Object value : Client.listPayload(result, "pairing_requests")) {
            Snapshots.PairingRequestSnapshot decoded = Client.decodePairingRequest(value);
            requests.add(new PairingRequest(client, route, decoded));
        }
        return List.copyOf(requests);
    }

    public FrontendProjection projection(Selector<Ids.ProjectionId> selector) {
        return new FrontendProjection(client, route, selector);
    }

    public SidebarView sidebarView(Selector<Ids.SidebarViewId> selector) {
        return new SidebarView(client, route, selector);
    }

    public Terminal terminal(Selector<Ids.TerminalId> selector) {
        return new Terminal(client, route, selector);
    }

    public Browser browser(Selector<Ids.BrowserId> selector) {
        return new Browser(client, route, selector);
    }

    public List<Terminal> listTerminals(Options.Read options) {
        Object result = client.requestValue(
            Operations.TERMINAL_LIST,
            withExtra(route.params(), options),
            null
        );
        List<Terminal> values = new ArrayList<>();
        for (Object value : Client.listPayload(result, "terminals")) {
            Snapshots.TerminalSnapshot decoded = Client.decodeTerminal(value);
            values.add(new Terminal(
                client, route, Selector.id(decoded.id()), decoded
            ));
        }
        return List.copyOf(values);
    }

    public List<Browser> listBrowsers(Options.Read options) {
        Object result = client.requestValue(
            Operations.BROWSER_LIST,
            withExtra(route.params(), options),
            null
        );
        List<Browser> values = new ArrayList<>();
        for (Object value : Client.listPayload(result, "browsers")) {
            Snapshots.BrowserSnapshot decoded = Client.decodeBrowser(value);
            values.add(new Browser(
                client, route, Selector.id(decoded.id()), decoded
            ));
        }
        return List.copyOf(values);
    }

    public List<Notification> listNotifications(Options.Read options) {
        Object result = client.requestValue(
            Operations.NOTIFICATION_LIST,
            withExtra(route.params(), options),
            null
        );
        List<Notification> values = new ArrayList<>();
        for (Object value : Client.listPayload(result, "notifications")) {
            values.add(new Notification(
                client, route, Client.decodeNotification(value)
            ));
        }
        return List.copyOf(values);
    }

    public MutationResult<Notification> createNotification(
        Options.NotificationCreate options
    ) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        params.put(Wire.TITLE, options.title());
        params.put(Wire.BODY, options.body());
        options.level().ifPresent(level -> params.put(Wire.LEVEL, level));
        options.terminalId().ifPresent(
            terminalId -> params.put("terminal_id", terminalId)
        );
        Client.MutationResponse response = client.mutation(
            Operations.NOTIFICATION_CREATE, params, options.mutation()
        );
        Snapshots.NotificationSnapshot decoded = Client.decodeNotification(
            Client.resourcePayload(response.result(), "notification")
        );
        return response.parts().withValue(new Notification(client, route, decoded));
    }

    public List<Agent> listAgents(Options.Read options) {
        Object result = client.requestValue(
            Operations.AGENT_LIST,
            withExtra(route.params(), options),
            null
        );
        List<Agent> values = new ArrayList<>();
        for (Object value : Client.listPayload(result, "agents")) {
            values.add(new Agent(client, route, Client.decodeAgent(value)));
        }
        return List.copyOf(values);
    }

    public MutationResult<Agent> reportAgent(Options.AgentReport options) {
        Map<String, Object> params = withExtra(
            route.params(), options.mutation().extra()
        );
        params.put("terminal_id", options.terminalId());
        params.put(Wire.STATE, options.state().toWire());
        params.put("source", options.source().toWire());
        options.sourceSession().ifPresent(
            value -> params.put("source_session", value)
        );
        Client.MutationResponse response = client.mutation(
            Operations.AGENT_REPORT, params, options.mutation()
        );
        Snapshots.AgentSnapshot decoded = Client.decodeAgent(
            Client.resourcePayload(response.result(), "agent")
        );
        return response.parts().withValue(new Agent(client, route, decoded));
    }

    public MutationResult<SidebarView> ensureSidebarView(
        Options.SidebarEnsure options
    ) {
        Map<String, Object> params = withExtra(
            route.params(), options.mutation().extra()
        );
        params.put(Wire.COLS, options.columns());
        params.put(Wire.ROWS, options.rows());
        options.relaunch().ifPresent(value -> params.put("relaunch", value));
        Client.MutationResponse response = client.mutation(
            Operations.SIDEBAR_VIEW_ENSURE, params, options.mutation()
        );
        Snapshots.SidebarViewSnapshot decoded = Client.decodeSidebarView(
            Client.resourcePayload(response.result(), "sidebar_view")
        );
        return response.parts().withValue(new SidebarView(
            client, route, Selector.id(decoded.id()), decoded
        ));
    }

    private static SessionEvent decodeEvent(
        Object value,
        Cursor envelopeCursor
    ) {
        if (envelopeCursor == null) {
            throw new ProtocolError(
                "session stream items require an envelope cursor"
            );
        }
        Map<String, Object> fields = Wire.object(value, "session event");
        String kind = Wire.string(fields.get(Wire.KIND), "session event kind");
        if (kind.equals("snapshot")) {
            Client.requireExactFields(
                fields,
                "session snapshot item",
                Wire.KIND,
                Wire.CURSOR,
                "reset_reason",
                "snapshot"
            );
            Optional<String> resetReason = Client.optionalString(
                fields,
                "reset_reason"
            );
            resetReason.ifPresent(reason -> {
                if (!List.of(
                        "initial",
                        "generation_changed",
                        "cursor_expired"
                    ).contains(reason)) {
                    throw new ProtocolError(
                        "session snapshot reset_reason is invalid"
                    );
                }
            });
            Cursor cursor = Client.decodeCursor(fields.get(Wire.CURSOR));
            requireEnvelopeCursor(cursor, envelopeCursor);
            return new SessionEvent.Snapshot(
                cursor,
                resetReason,
                Client.decodeResourceSnapshot(fields.get("snapshot"))
            );
        }
        if (kind.equals("delta")) {
            Client.requireExactFields(
                fields,
                "session delta item",
                Wire.KIND,
                Wire.CURSOR,
                "previous_revision",
                Wire.REVISION,
                "changes"
            );
            List<ResourceChange> changes = Wire.array(
                fields.get("changes"),
                "session changes"
            ).stream().map(Client::decodeResourceChange).toList();
            Cursor cursor = Client.decodeCursor(fields.get(Wire.CURSOR));
            requireEnvelopeCursor(cursor, envelopeCursor);
            return new SessionEvent.Delta(
                cursor,
                Wire.decimal(
                    fields.get("previous_revision"),
                    "session previous_revision"
                ),
                Wire.decimal(
                    fields.get(Wire.REVISION),
                    "session revision"
                ),
                changes
            );
        }
        return new SessionEvent.Unknown(kind, fields);
    }

    private static SessionJournalRecord decodeJournalRecord(
        Object value,
        Cursor envelopeCursor
    ) {
        if (envelopeCursor == null) {
            throw new ProtocolError("journal stream items require an envelope cursor");
        }
        Map<String, Object> fields = Wire.object(value, "session journal record");
        Client.requireExactFields(
            fields,
            "session journal record",
            "sequence", "event_id", "schema_version", Wire.KIND, "class", "replay",
            "occurred_at_ms", "committed_at_ms", "producer", "authority",
            "causation_id", "correlation_id", "causation_depth", "subjects",
            "sensitivity", "payload", "resource_revision", "previous_resource_revision"
        );
        for (String required : List.of("authority", "payload")) {
            if (!fields.containsKey(required)) {
                throw new ProtocolError(
                    "session journal record omitted required field " + required
                );
            }
        }
        Decimal sequence = Wire.decimal(fields.get("sequence"), "journal sequence");
        if (!sequence.equals(envelopeCursor.revision())) {
            throw new ProtocolError("journal sequence must match its stream cursor");
        }
        int schemaVersion = Client.integer(fields, "schema_version");
        int causationDepth = Client.integer(fields, "causation_depth");
        if (schemaVersion < 1 || causationDepth < 0 || causationDepth > 65_535) {
            throw new ProtocolError("journal numeric fields are outside their allowed range");
        }
        Map<String, Object> producer = Wire.object(fields.get("producer"), "journal producer");
        Client.requireExactFields(producer, "journal producer", Wire.KIND, "id");
        Optional<SessionJournalRecord.Authority> authority = Optional.empty();
        if (fields.get("authority") != null) {
            Map<String, Object> raw = Wire.object(fields.get("authority"), "journal authority");
            Client.requireExactFields(
                raw, "journal authority", "principal_id", "lease_id", Wire.GENERATION, "role"
            );
            authority = Optional.of(new SessionJournalRecord.Authority(
                Wire.string(raw.get("principal_id"), "journal principal_id"),
                Wire.string(raw.get("lease_id"), "journal lease_id"),
                Wire.string(raw.get(Wire.GENERATION), "journal generation"),
                Wire.string(raw.get("role"), "journal role")
            ));
        }
        List<SessionJournalRecord.Subject> subjects = Wire.array(
            fields.get("subjects"), "journal subjects"
        ).stream().map(subjectValue -> {
            Map<String, Object> subject = Wire.object(subjectValue, "journal subject");
            Client.requireExactFields(subject, "journal subject", Wire.KIND, "id");
            return new SessionJournalRecord.Subject(
                Wire.string(subject.get(Wire.KIND), "journal subject kind"),
                Wire.string(subject.get("id"), "journal subject id")
            );
        }).toList();
        try {
            return new SessionJournalRecord(
                sequence,
                Wire.string(fields.get("event_id"), "journal event_id"),
                schemaVersion,
                Wire.string(fields.get(Wire.KIND), "journal kind"),
                SessionJournalRecord.JournalClass.valueOf(
                    Wire.string(fields.get("class"), "journal class")
                        .toUpperCase(java.util.Locale.ROOT)
                ),
                SessionJournalRecord.ReplayPolicy.valueOf(
                    Wire.string(fields.get("replay"), "journal replay")
                        .toUpperCase(java.util.Locale.ROOT)
                ),
                Wire.decimal(fields.get("occurred_at_ms"), "journal occurred_at_ms"),
                Wire.decimal(fields.get("committed_at_ms"), "journal committed_at_ms"),
                new SessionJournalRecord.Producer(
                    Wire.string(producer.get(Wire.KIND), "journal producer kind"),
                    Wire.string(producer.get("id"), "journal producer id")
                ),
                authority,
                Client.requiredNullableString(fields, "causation_id"),
                Client.requiredNullableString(fields, "correlation_id"),
                causationDepth,
                subjects,
                SessionJournalRecord.Sensitivity.valueOf(
                    Wire.string(fields.get("sensitivity"), "journal sensitivity")
                        .toUpperCase(java.util.Locale.ROOT)
                ),
                JsonValue.of(fields.get("payload")),
                requiredNullableDecimal(fields, "resource_revision"),
                requiredNullableDecimal(fields, "previous_resource_revision")
            );
        } catch (IllegalArgumentException error) {
            throw new ProtocolError("invalid session journal record", error);
        }
    }

    private static Optional<Decimal> requiredNullableDecimal(
        Map<String, Object> fields,
        String key
    ) {
        if (!fields.containsKey(key)) {
            throw new ProtocolError(key + " is required, although it may be null");
        }
        return fields.get(key) == null
            ? Optional.empty()
            : Optional.of(Wire.decimal(fields.get(key), key));
    }

    private static void requireEnvelopeCursor(
        Cursor item,
        Cursor envelope
    ) {
        if (envelope == null || !item.equals(envelope)) {
            throw new ProtocolError(
                "session item cursor must match its stream envelope"
            );
        }
    }

    private static Map<String, Object> cursorMap(Cursor cursor) {
        return Map.of(
            Wire.GENERATION, cursor.generation(),
            Wire.REVISION, cursor.revision()
        );
    }

    private static Map<String, Object> withExtra(
        Map<String, Object> params,
        Options.Read options
    ) {
        return withExtra(params, options == null ? Map.of() : options.extra());
    }

    private static Map<String, Object> withExtra(
        Map<String, Object> params,
        Map<String, Object> extra
    ) {
        params.putAll(extra);
        return params;
    }
}
