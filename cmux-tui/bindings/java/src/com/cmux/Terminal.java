package com.cmux;

import com.cmux.internal.Operations;
import com.cmux.internal.Wire;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

public final class Terminal {
    private final Client client;
    private final Route route;
    private final Selector<Ids.TerminalId> selector;
    private volatile Snapshots.TerminalSnapshot snapshot;

    Terminal(Client client, Route route, Selector<Ids.TerminalId> selector) {
        this(client, route, selector, null);
    }

    Terminal(
        Client client,
        Route route,
        Selector<Ids.TerminalId> selector,
        Snapshots.TerminalSnapshot snapshot
    ) {
        this.client = Objects.requireNonNull(client, "client");
        this.route = Objects.requireNonNull(route, "route");
        this.selector = Objects.requireNonNull(selector, "selector");
        this.snapshot = snapshot;
    }

    public Optional<Snapshots.TerminalSnapshot> cached() {
        return Optional.ofNullable(snapshot);
    }

    public Snapshots.TerminalSnapshot refresh() {
        snapshot = Client.decodeTerminal(Client.resourcePayload(
            client.request(Operations.TERMINAL_GET, params(), null),
            Wire.TERMINAL
        ));
        return snapshot;
    }

    public MutationResult<EmptyResult> write(Options.TerminalWrite options) {
        Map<String, Object> params = withExtra(params(), options.mutation().extra());
        options.text().ifPresent(value -> params.put(Wire.TEXT, value));
        options.bytes().ifPresent(value -> params.put(
            "bytes_base64", Base64.getEncoder().encodeToString(value)
        ));
        return emptyMutation(Operations.TERMINAL_INPUT_WRITE, params, options.mutation());
    }

    public MutationResult<EmptyResult> keys(Options.TerminalKeys options) {
        Map<String, Object> params = withExtra(params(), options.mutation().extra());
        params.put(Wire.KEYS, options.keys());
        return emptyMutation(Operations.TERMINAL_INPUT_KEYS, params, options.mutation());
    }

    public MutationResult<EmptyResult> mouse(Options.Mouse options) {
        Map<String, Object> params = withExtra(params(), options.mutation().extra());
        params.putAll(options.mouse());
        return emptyMutation(Operations.TERMINAL_INPUT_MOUSE, params, options.mutation());
    }

    public MutationResult<EmptyResult> focusInput(Options.FocusInput options) {
        Map<String, Object> params = withExtra(params(), options.mutation().extra());
        params.put(Wire.FOCUSED, options.focused());
        return emptyMutation(Operations.TERMINAL_INPUT_FOCUS, params, options.mutation());
    }

    public Document readScreen(Options.Read options) {
        return read(Operations.TERMINAL_SCREEN_READ, options);
    }

    public Document readState(Options.Read options) {
        return read(Operations.TERMINAL_STATE_READ, options);
    }

    public Document readHistory(Options.HistoryRead options) {
        Map<String, Object> params = withExtra(params(), options.read().extra());
        options.before().ifPresent(value -> params.put("before", value));
        options.limit().ifPresent(value -> params.put("limit", value));
        if (options.styled()) {
            params.put("styled", true);
        }
        return Client.document(client.request(
            Operations.TERMINAL_HISTORY_READ, params, null
        ));
    }

    public MutationResult<EmptyResult> clearHistory(Options.Mutation options) {
        return emptyMutation(
            Operations.TERMINAL_HISTORY_CLEAR,
            withExtra(params(), options.extra()),
            options
        );
    }

    public Document waitFor(Options.Wait options) {
        Map<String, Object> params = withExtra(params(), options.read().extra());
        params.put("pattern", options.condition());
        if (options.timeoutMillis() > 0) {
            params.put(Wire.TIMEOUT_MS, Long.toUnsignedString(options.timeoutMillis()));
        }
        return Client.document(client.request(Operations.TERMINAL_WAIT, params, null));
    }

    public Document copy(Options.Copy options) {
        Map<String, Object> params = withExtra(params(), options.read().extra());
        if (!options.mode().isEmpty()) {
            params.put(Wire.MODE, options.mode());
        }
        return Client.document(client.request(Operations.TERMINAL_COPY, params, null));
    }

    public Document process(Options.Read options) {
        return read(Operations.TERMINAL_PROCESS_GET, options);
    }

    public RendererGrant createRendererGrant(Options.RendererGrant options) {
        Map<String, Object> params = withExtra(params(), options.control().extra());
        options.ttlMillis().ifPresent(value -> params.put("ttl_ms", value));
        Map<String, Object> result = client.request(
            Operations.TERMINAL_RENDERER_GRANT_CREATE, params, null
        );
        Map<String, Object> fields = new LinkedHashMap<>(
            Client.resourcePayload(result, "grant")
        );
        String endpoint = Wire.string(fields.remove("endpoint"), "renderer endpoint");
        Ids.TerminalId terminal = new Ids.TerminalId(
            Wire.string(fields.remove("terminal_id"), "renderer terminal id")
        );
        Secret token = new Secret(
            Wire.string(fields.remove("token"), "renderer token")
        );
        List<String> rights = new ArrayList<>();
        for (Object value : Wire.array(fields.remove("rights"), "renderer rights")) {
            rights.add(Wire.string(value, "renderer right"));
        }
        int ttl = ((Number) fields.remove("ttl_ms")).intValue();
        return new RendererGrant(endpoint, terminal, token, rights, ttl);
    }

    public Document resizeViewer(Options.ViewerSize options) {
        Map<String, Object> params = withExtra(params(), options.control().extra());
        params.put(Wire.COLS, options.width());
        params.put(Wire.ROWS, options.height());
        return Client.document(client.request(
            Operations.TERMINAL_VIEWER_RESIZE, params, null
        ));
    }

    public Document releaseViewer(Options.Control options) {
        return Client.document(client.request(
            Operations.TERMINAL_VIEWER_RELEASE,
            withExtra(params(), options == null ? Map.of() : options.extra()),
            null
        ));
    }

    public MutationResult<EmptyResult> scrollViewport(Options.Scroll options) {
        Map<String, Object> params = withExtra(params(), options.mutation().extra());
        params.put("delta_rows", options.delta());
        return emptyMutation(
            Operations.TERMINAL_VIEWPORT_SCROLL, params, options.mutation()
        );
    }

    public MutationResult<Snapshots.TerminalSnapshot> move(
        Options.TerminalMove options
    ) {
        Map<String, Object> params = withExtra(params(), options.mutation().extra());
        params.put("destination_workspace", options.workspace());
        params.put("destination_screen", options.screen());
        params.put("destination_pane", options.pane());
        params.put("index", options.index());
        Client.MutationResponse response = client.mutation(
            Operations.TERMINAL_MOVE, params, options.mutation()
        );
        snapshot = Client.decodeTerminal(
            Client.resourcePayload(response.result(), Wire.TERMINAL)
        );
        return response.parts().withValue(snapshot);
    }

    public ResourceStream<TerminalAttachmentItem> attach(
        Options.TerminalAttach options
    ) {
        Map<String, Object> params = withExtra(params(), options.stream().extra());
        options.columns().ifPresent(value -> params.put(Wire.COLS, value));
        options.rows().ifPresent(value -> params.put(Wire.ROWS, value));
        if (options.readOnly()) {
            params.put("read_only", true);
        }
        return client.openStream(
            Operations.TERMINAL_ATTACH, params, Terminal::decodeAttachment
        );
    }

    public MutationResult<EmptyResult> close(Options.Mutation options) {
        return emptyMutation(
            Operations.TERMINAL_CLOSE,
            withExtra(params(), options.extra()),
            options
        );
    }

    private Map<String, Object> params() {
        return route.target(Wire.TERMINAL, selector);
    }

    private Document read(Operations operation, Options.Read options) {
        return Client.document(client.request(
            operation,
            withExtra(params(), options == null ? Map.of() : options.extra()),
            null
        ));
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

    private static TerminalAttachmentItem decodeAttachment(Object value) {
        Map<String, Object> fields = Wire.object(value, "terminal attachment");
        String kind = Wire.string(fields.get(Wire.KIND), "terminal item kind");
        if (kind.equals("snapshot") || kind.equals("patch")) {
            Client.requireExactFields(
                fields,
                "terminal " + kind + " item",
                Wire.KIND,
                "terminal_id",
                "render"
            );
            return new TerminalAttachmentItem(
                kind,
                Optional.of(new Ids.TerminalId(
                    Wire.string(fields.get("terminal_id"), "terminal item id")
                )),
                Wire.object(fields.get("render"), "terminal render"),
                Map.of(),
                Map.of()
            );
        }
        if (kind.equals("scroll")) {
            Client.requireExactFields(
                fields,
                "terminal scroll item",
                Wire.KIND,
                "terminal_id",
                "scroll"
            );
            return new TerminalAttachmentItem(
                kind,
                Optional.of(new Ids.TerminalId(
                    Wire.string(fields.get("terminal_id"), "terminal item id")
                )),
                Map.of(),
                Wire.object(fields.get("scroll"), "terminal scroll"),
                Map.of()
            );
        }
        return new TerminalAttachmentItem(
            kind,
            Optional.empty(),
            Map.of(),
            Map.of(),
            fields
        );
    }

    private static Map<String, Object> withExtra(
        Map<String, Object> params,
        Map<String, Object> extra
    ) {
        params.putAll(extra);
        return params;
    }
}
