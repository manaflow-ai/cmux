package com.cmux;

import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** Immutable, operation-specific caller inputs. */
public final class Options {
    public enum Direction { LEFT, RIGHT, UP, DOWN;
        public String toWire() { return name().toLowerCase(java.util.Locale.ROOT); }
    }

    public enum InitialContent { TERMINAL, EMPTY;
        public String toWire() { return name().toLowerCase(java.util.Locale.ROOT); }
    }

    public enum PairingDecision { ACCEPT, REJECT;
        public String toWire() { return name().toLowerCase(java.util.Locale.ROOT); }
    }

    public enum AgentState { WORKING, BLOCKED, IDLE, DONE, UNKNOWN;
        public String toWire() { return name().toLowerCase(java.util.Locale.ROOT); }
    }

    public enum AgentSource { HOOK, SOCKET;
        public String toWire() { return name().toLowerCase(java.util.Locale.ROOT); }
    }

    public record Read(Map<String, Object> extra) {
        public Read { extra = copy(extra); }
        public static Read defaults() { return new Read(Map.of()); }
    }

    public record Control(Map<String, Object> extra) {
        public Control { extra = copy(extra); }
        public static Control defaults() { return new Control(Map.of()); }
    }

    public record Stream(Map<String, Object> extra) {
        public Stream { extra = copy(extra); }
        public static Stream defaults() { return new Stream(Map.of()); }
    }

    public record Mutation(
        Optional<String> idempotencyKey,
        Optional<Decimal> expectedRevision,
        Map<String, Object> extra
    ) {
        public Mutation {
            idempotencyKey = opt(idempotencyKey);
            expectedRevision = opt(expectedRevision);
            idempotencyKey.ifPresent(key -> {
                if (key.isEmpty() || key.length() > 128) {
                    throw new IllegalArgumentException("idempotency key must contain 1 to 128 characters");
                }
            });
            extra = copy(extra);
        }
        public static Mutation defaults() {
            return new Mutation(Optional.empty(), Optional.empty(), Map.of());
        }
        public static Mutation keyed(String key) {
            return new Mutation(Optional.of(key), Optional.empty(), Map.of());
        }
        public Mutation expecting(Decimal revision) {
            return new Mutation(idempotencyKey, Optional.of(revision), extra);
        }
    }

    /** Three-state optional nullable string. */
    public record NullableString(boolean present, Optional<String> value) {
        public NullableString { value = opt(value); }
        public static NullableString absent() { return new NullableString(false, Optional.empty()); }
        public static NullableString nullValue() { return new NullableString(true, Optional.empty()); }
        public static NullableString of(String value) {
            return new NullableString(true, Optional.of(Objects.requireNonNull(value, "value")));
        }
        public Object toWire() { return value.orElse(null); }
    }

    public record MachineCreate(Mutation mutation) {
        public MachineCreate {
            mutation = mut(mutation);
        }
    }
    public record MachineRename(
        Mutation mutation,
        String name,
        boolean confirmClose
    ) {
        public MachineRename {
            mutation = mut(mutation);
            Objects.requireNonNull(name, "name");
        }

        public MachineRename(Mutation mutation, String name) {
            this(mutation, name, false);
        }
    }
    public record MachineDelete(Mutation mutation) {
        public MachineDelete { mutation = mut(mutation); }
    }
    public record MachineConnectExternal(
        Mutation mutation,
        ExternalMachineSpecifier specifier
    ) {
        public MachineConnectExternal {
            mutation = mut(mutation);
            Objects.requireNonNull(specifier, "specifier");
        }
    }
    public record SessionOpen(Mutation mutation) {
        public SessionOpen { mutation = mut(mutation); }
    }
    public record SessionEvents(Stream stream, Optional<Cursor> cursor) {
        public SessionEvents { stream = Options.stream(stream); cursor = opt(cursor); }
    }
    public record TerminalDefaults(Mutation mutation, Map<String, Object> defaults) {
        public TerminalDefaults { mutation = mut(mutation); defaults = copy(defaults); }
    }
    public record SessionShutdown(Mutation mutation, boolean force) {
        public SessionShutdown { mutation = mut(mutation); }
    }
    public record WindowTitle(Mutation mutation, String title) {
        public WindowTitle { mutation = mut(mutation); Objects.requireNonNull(title, "title"); }
    }
    public record ClientMetadata(
        Control control,
        NullableString name,
        NullableString kind
    ) {
        public ClientMetadata {
            control = Options.control(control);
            name = name == null ? NullableString.absent() : name;
            kind = kind == null ? NullableString.absent() : kind;
        }
        public static Builder builder() { return new Builder(); }
        public static final class Builder {
            private Control control = Control.defaults();
            private NullableString name = NullableString.absent();
            private NullableString kind = NullableString.absent();
            public Builder control(Control value) { control = value; return this; }
            public Builder name(String value) { name = NullableString.of(value); return this; }
            public Builder clearName() { name = NullableString.nullValue(); return this; }
            public Builder kind(String value) { kind = NullableString.of(value); return this; }
            public Builder clearKind() { kind = NullableString.nullValue(); return this; }
            public ClientMetadata build() { return new ClientMetadata(control, name, kind); }
        }
    }
    public record ClientSizing(
        Control control,
        boolean enabled,
        Optional<Boolean> exclusive
    ) {
        public ClientSizing {
            control = Options.control(control);
            exclusive = opt(exclusive);
        }

        public ClientSizing(Control control, boolean enabled) {
            this(control, enabled, Optional.empty());
        }
    }
    public record CellPixels(Control control, int width, int height) {
        public CellPixels { control = Options.control(control); nonnegative(width, "width"); nonnegative(height, "height"); }
    }
    public record PairingResolve(Mutation mutation, PairingDecision decision) {
        public PairingResolve {
            mutation = mut(mutation);
            Objects.requireNonNull(decision, "decision");
        }
    }
    public record ProjectionPut(Mutation mutation, Map<String, Object> projection) {
        public ProjectionPut {
            mutation = mut(mutation);
            projection = copy(projection);
        }
    }
    public record WorkspaceCreate(
        Mutation mutation,
        Optional<String> name,
        InitialContent initialContent
    ) {
        public WorkspaceCreate {
            mutation = mut(mutation); name = opt(name);
            initialContent = initialContent == null ? InitialContent.TERMINAL : initialContent;
        }
        public static Builder builder() { return new Builder(); }
        public static final class Builder {
            private Mutation mutation = Mutation.defaults();
            private String name;
            private InitialContent initialContent = InitialContent.TERMINAL;
            public Builder mutation(Mutation value) { mutation = value; return this; }
            public Builder name(String value) { name = value; return this; }
            public Builder initialContent(InitialContent value) { initialContent = value; return this; }
            public WorkspaceCreate build() {
                return new WorkspaceCreate(mutation, Optional.ofNullable(name), initialContent);
            }
        }
    }
    public record WorkspaceRename(Mutation mutation, String name) {
        public WorkspaceRename { mutation = mut(mutation); Objects.requireNonNull(name, "name"); }
    }
    public record WorkspaceMove(
        Mutation mutation,
        int index
    ) {
        public WorkspaceMove { mutation = mut(mutation); nonnegative(index, "index"); }
    }
    public record Run(
        Mutation mutation,
        Command command,
        Optional<String> cwd,
        Optional<String> name,
        Optional<Integer> columns,
        Optional<Integer> rows
    ) {
        public Run {
            mutation = mut(mutation); Objects.requireNonNull(command, "command");
            cwd = opt(cwd); name = opt(name); columns = opt(columns); rows = opt(rows);
        }
        public static Builder builder(Command command) { return new Builder(command); }
        public static final class Builder {
            private Mutation mutation = Mutation.defaults();
            private final Command command;
            private String cwd;
            private String name;
            private Integer columns;
            private Integer rows;
            private Builder(Command command) { this.command = Objects.requireNonNull(command, "command"); }
            public Builder mutation(Mutation value) { mutation = value; return this; }
            public Builder cwd(String value) { cwd = value; return this; }
            public Builder name(String value) { name = value; return this; }
            public Builder size(int cols, int rowCount) { columns = cols; rows = rowCount; return this; }
            public Run build() {
                return new Run(
                    mutation,
                    command,
                    Optional.ofNullable(cwd),
                    Optional.ofNullable(name),
                    Optional.ofNullable(columns),
                    Optional.ofNullable(rows)
                );
            }
        }
    }
    public record LayoutApply(Mutation mutation, Map<String, Object> layout) {
        public LayoutApply { mutation = mut(mutation); layout = copy(layout); }
    }
    public record ScreenCreate(Mutation mutation, Optional<String> name) {
        public ScreenCreate { mutation = mut(mutation); name = opt(name); }
    }
    public record ScreenRename(Mutation mutation, String name) {
        public ScreenRename { mutation = mut(mutation); Objects.requireNonNull(name, "name"); }
    }
    public record PaneRename(Mutation mutation, String name) {
        public PaneRename { mutation = mut(mutation); Objects.requireNonNull(name, "name"); }
    }
    public record TabRename(Mutation mutation, String name) {
        public TabRename { mutation = mut(mutation); Objects.requireNonNull(name, "name"); }
    }
    public record LayoutUndo(Mutation mutation, boolean confirm) {
        public LayoutUndo { mutation = mut(mutation); }
    }
    public record PaneCreate(
        Mutation mutation,
        Optional<String> cwd,
        Optional<Integer> columns,
        Optional<Integer> rows
    ) {
        public PaneCreate { mutation = mut(mutation); cwd = opt(cwd); columns = opt(columns); rows = opt(rows); }
    }
    public record PaneSplit(
        Mutation mutation,
        Direction direction,
        Optional<Double> ratio,
        Optional<String> cwd,
        Optional<Integer> columns,
        Optional<Integer> rows
    ) {
        public PaneSplit {
            mutation = mut(mutation); Objects.requireNonNull(direction, "direction");
            ratio = opt(ratio); cwd = opt(cwd); columns = opt(columns); rows = opt(rows);
        }
    }
    public record DirectionInput(Mutation mutation, Direction direction) {
        public DirectionInput { mutation = mut(mutation); Objects.requireNonNull(direction, "direction"); }
    }
    public record DirectionRead(Read read, Direction direction) {
        public DirectionRead { read = Options.read(read); Objects.requireNonNull(direction, "direction"); }
    }
    public record PaneSwap(
        Mutation mutation,
        Selector<Ids.WorkspaceId> workspace,
        Selector<Ids.ScreenId> screen,
        Selector<Ids.PaneId> pane
    ) {
        public PaneSwap {
            mutation = mut(mutation); Objects.requireNonNull(workspace, "workspace");
            Objects.requireNonNull(screen, "screen"); Objects.requireNonNull(pane, "pane");
        }
    }
    public record PaneZoom(Mutation mutation, Optional<Boolean> enabled) {
        public PaneZoom { mutation = mut(mutation); enabled = opt(enabled); }
    }
    public record Ratio(Mutation mutation, Ids.SplitId splitId, double ratio) {
        public Ratio { mutation = mut(mutation); Objects.requireNonNull(splitId, "splitId"); finite(ratio, "ratio"); }
    }
    public record Width(Mutation mutation, int width) {
        public Width { mutation = mut(mutation); nonnegative(width, "width"); }
    }
    public record TabCreateTerminal(
        Mutation mutation,
        Optional<String> name,
        Optional<String> cwd,
        Optional<Integer> columns,
        Optional<Integer> rows
    ) {
        public TabCreateTerminal { mutation = mut(mutation); name = opt(name); cwd = opt(cwd); columns = opt(columns); rows = opt(rows); }
    }
    public record TabCreateBrowser(
        Mutation mutation,
        Optional<String> name,
        String url,
        Optional<Integer> width,
        Optional<Integer> height
    ) {
        public TabCreateBrowser { mutation = mut(mutation); name = opt(name); Objects.requireNonNull(url, "url"); width = opt(width); height = opt(height); }
    }
    public record TabMove(
        Mutation mutation,
        Selector<Ids.WorkspaceId> workspace,
        Selector<Ids.ScreenId> screen,
        Selector<Ids.PaneId> pane,
        int index
    ) {
        public TabMove {
            mutation = mut(mutation); Objects.requireNonNull(workspace, "workspace");
            Objects.requireNonNull(screen, "screen"); Objects.requireNonNull(pane, "pane");
            nonnegative(index, "index");
        }
    }
    public record TerminalWrite(
        Mutation mutation,
        Optional<String> text,
        Optional<byte[]> bytes
    ) {
        public TerminalWrite {
            mutation = mut(mutation); text = opt(text); bytes = opt(bytes);
            if (text.isPresent() == bytes.isPresent()) {
                throw new IllegalArgumentException("exactly one of text or bytes is required");
            }
            bytes = bytes.map(value -> value.clone());
        }
        public static TerminalWrite text(Mutation mutation, String value) {
            return new TerminalWrite(mutation, Optional.of(value), Optional.empty());
        }
        public static TerminalWrite bytes(Mutation mutation, byte[] value) {
            return new TerminalWrite(mutation, Optional.empty(), Optional.of(value.clone()));
        }
        @Override public Optional<byte[]> bytes() {
            return bytes.map(value -> value.clone());
        }
    }
    public record TerminalKeys(Mutation mutation, List<Map<String, Object>> keys) {
        public TerminalKeys { mutation = mut(mutation); keys = List.copyOf(keys); }
    }
    public record Mouse(Mutation mutation, Map<String, Object> mouse) {
        public Mouse { mutation = mut(mutation); mouse = copy(mouse); }
    }
    public record FocusInput(Mutation mutation, boolean focused) {
        public FocusInput { mutation = mut(mutation); }
    }
    public record Page(Read read, long start, int count) {
        public Page { read = Options.read(read); nonnegative(start, "start"); nonnegative(count, "count"); }
    }
    public record HistoryRead(
        Read read,
        Optional<Decimal> before,
        Optional<Integer> limit,
        boolean styled
    ) {
        public HistoryRead { read = Options.read(read); before = opt(before); limit = opt(limit); }
    }
    public record Wait(Read read, String condition, long timeoutMillis) {
        public Wait { read = Options.read(read); Objects.requireNonNull(condition, "condition"); nonnegative(timeoutMillis, "timeoutMillis"); }
    }
    public record Copy(Read read, String mode) {
        public Copy { read = Options.read(read); Objects.requireNonNull(mode, "mode"); }
    }
    public record RendererGrant(Control control, Optional<Integer> ttlMillis) {
        public RendererGrant {
            control = Options.control(control); ttlMillis = opt(ttlMillis);
            ttlMillis.ifPresent(value -> {
                if (value < 1 || value > 60_000) {
                    throw new IllegalArgumentException("ttlMillis must be between 1 and 60000");
                }
            });
        }
    }
    public record ViewerSize(Control control, int width, int height) {
        public ViewerSize { control = Options.control(control); nonnegative(width, "width"); nonnegative(height, "height"); }
    }
    public record Scroll(Mutation mutation, long delta) {
        public Scroll { mutation = mut(mutation); }
    }
    public record TerminalMove(
        Mutation mutation,
        Selector<Ids.WorkspaceId> workspace,
        Selector<Ids.ScreenId> screen,
        Selector<Ids.PaneId> pane,
        int index
    ) {
        public TerminalMove {
            mutation = mut(mutation); Objects.requireNonNull(workspace, "workspace");
            Objects.requireNonNull(screen, "screen"); Objects.requireNonNull(pane, "pane");
            nonnegative(index, "index");
        }
    }
    public record TerminalAttach(Stream stream, Optional<Integer> columns, Optional<Integer> rows, boolean readOnly) {
        public TerminalAttach { stream = Options.stream(stream); columns = opt(columns); rows = opt(rows); }
    }
    public record Navigate(Mutation mutation, String url) {
        public Navigate { mutation = mut(mutation); Objects.requireNonNull(url, "url"); }
    }
    public record Reload(Mutation mutation, boolean ignoreCache) {
        public Reload { mutation = mut(mutation); }
    }
    public record Key(Mutation mutation, Map<String, Object> key) {
        public Key { mutation = mut(mutation); key = copy(key); }
    }
    public record Text(Mutation mutation, String text) {
        public Text { mutation = mut(mutation); Objects.requireNonNull(text, "text"); }
    }
    public record Wheel(
        Mutation mutation,
        double deltaX,
        double deltaY,
        Optional<Double> x,
        Optional<Double> y
    ) {
        public Wheel {
            mutation = mut(mutation);
            finite(deltaX, "deltaX");
            finite(deltaY, "deltaY");
            x = opt(x);
            y = opt(y);
            x.ifPresent(value -> finite(value, "x"));
            y.ifPresent(value -> finite(value, "y"));
        }

        public Wheel(Mutation mutation, double deltaX, double deltaY) {
            this(
                mutation,
                deltaX,
                deltaY,
                Optional.empty(),
                Optional.empty()
            );
        }
    }
    public record BrowserAttach(Stream stream, Optional<Integer> width, Optional<Integer> height) {
        public BrowserAttach { stream = Options.stream(stream); width = opt(width); height = opt(height); }
    }
    public record NotificationCreate(Mutation mutation, String title, String body, Optional<String> level) {
        public NotificationCreate { mutation = mut(mutation); Objects.requireNonNull(title, "title"); Objects.requireNonNull(body, "body"); level = opt(level); }
    }
    public record AgentReport(
        Mutation mutation,
        Ids.TerminalId terminalId,
        AgentState state,
        AgentSource source,
        Optional<String> sourceSession
    ) {
        public AgentReport {
            mutation = mut(mutation);
            Objects.requireNonNull(terminalId, "terminalId");
            Objects.requireNonNull(state, "state");
            Objects.requireNonNull(source, "source");
            sourceSession = opt(sourceSession);
        }
    }
    public record SidebarEnsure(
        Mutation mutation,
        int columns,
        int rows,
        Optional<Boolean> relaunch
    ) {
        public SidebarEnsure {
            mutation = mut(mutation);
            positive(columns, "columns");
            positive(rows, "rows");
            relaunch = opt(relaunch);
        }
    }
    public record SidebarInput(Mutation mutation, byte[] input) {
        public SidebarInput { mutation = mut(mutation); input = input.clone(); }
        @Override public byte[] input() { return input.clone(); }
    }
    public record SidebarResize(Mutation mutation, int columns, int rows) {
        public SidebarResize { mutation = mut(mutation); nonnegative(columns, "columns"); nonnegative(rows, "rows"); }
    }
    public record ProviderInvoke(Mutation mutation, Map<String, Object> parameters) {
        public ProviderInvoke {
            mutation = mut(mutation);
            parameters = copy(parameters);
        }
    }
    public record ProviderNotices(Stream stream, Optional<Cursor> cursor) {
        public ProviderNotices { stream = Options.stream(stream); cursor = opt(cursor); }
    }
    public record ProviderWorkspace(
        Mutation mutation,
        Selector<Ids.WorkspaceId> workspace,
        boolean managed
    ) {
        public ProviderWorkspace {
            mutation = mut(mutation);
            Objects.requireNonNull(workspace, "workspace");
        }
    }
    public record ProviderWorkspaceRename(
        Mutation mutation,
        Selector<Ids.WorkspaceId> workspace,
        NullableString name
    ) {
        public ProviderWorkspaceRename {
            mutation = mut(mutation);
            Objects.requireNonNull(workspace, "workspace");
            Objects.requireNonNull(name, "name");
            if (!name.present()) {
                throw new IllegalArgumentException("name must be present");
            }
        }
    }
    public record ProviderWorkspaceClose(
        Mutation mutation,
        Selector<Ids.WorkspaceId> workspace
    ) {
        public ProviderWorkspaceClose {
            mutation = mut(mutation);
            Objects.requireNonNull(workspace, "workspace");
        }
    }

    private Options() {}

    private static Mutation mut(Mutation value) { return value == null ? Mutation.defaults() : value; }
    private static Read read(Read value) { return value == null ? Read.defaults() : value; }
    private static Control control(Control value) { return value == null ? Control.defaults() : value; }
    private static Stream stream(Stream value) { return value == null ? Stream.defaults() : value; }
    private static <T> Optional<T> opt(Optional<T> value) { return value == null ? Optional.empty() : value; }
    private static Map<String, Object> copy(Map<String, Object> value) { return value == null ? Map.of() : Map.copyOf(value); }
    private static void nonnegative(long value, String name) { if (value < 0) throw new IllegalArgumentException(name + " must not be negative"); }
    private static void positive(long value, String name) { if (value <= 0) throw new IllegalArgumentException(name + " must be positive"); }
    private static void finite(double value, String name) { if (!Double.isFinite(value)) throw new IllegalArgumentException(name + " must be finite"); }
}
