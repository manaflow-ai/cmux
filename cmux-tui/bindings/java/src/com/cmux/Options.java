package com.cmux;

import java.nio.charset.StandardCharsets;
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
            idempotencyKey.ifPresent(Options::validateIdempotencyKey);
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

    public record SessionOpen(Mutation mutation) {
        public SessionOpen { mutation = mut(mutation); }
    }
    public record SessionEvents(Stream stream, Optional<Cursor> cursor) {
        public SessionEvents { stream = Options.stream(stream); cursor = opt(cursor); }
    }
    public enum JournalStart { TAIL, BEGINNING;
        public String toWire() { return name().toLowerCase(java.util.Locale.ROOT); }
    }
    public record JournalSubjectFilter(
        Optional<String> kind,
        Optional<String> id
    ) {
        public JournalSubjectFilter { kind = opt(kind); id = opt(id); }
    }
    public enum JournalRegexField { KIND, SUBJECTS, PAYLOAD, RECORD, TERMINAL_OUTPUT;
        public String toWire() { return name().toLowerCase(java.util.Locale.ROOT); }
    }
    public record JournalRegexFilter(
        String pattern,
        JournalRegexField field,
        boolean caseSensitive
    ) {
        public JournalRegexFilter(String pattern) {
            this(pattern, JournalRegexField.RECORD, true);
        }

        public JournalRegexFilter {
            Objects.requireNonNull(pattern, "pattern");
            field = field == null ? JournalRegexField.RECORD : field;
            if (pattern.isEmpty() || pattern.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 1024) {
                throw new IllegalArgumentException("journal regex must contain 1 to 1024 UTF-8 bytes");
            }
        }
    }
    public record JournalFilter(
        List<String> kinds,
        List<SessionJournalRecord.JournalClass> classes,
        List<JournalSubjectFilter> subjects,
        Optional<SessionJournalRecord.Sensitivity> maxSensitivity,
        Optional<JournalRegexFilter> regex
    ) {
        public JournalFilter(
            List<String> kinds,
            List<SessionJournalRecord.JournalClass> classes,
            List<JournalSubjectFilter> subjects,
            Optional<SessionJournalRecord.Sensitivity> maxSensitivity
        ) {
            this(kinds, classes, subjects, maxSensitivity, Optional.empty());
        }

        public JournalFilter {
            kinds = kinds == null ? List.of() : List.copyOf(kinds);
            classes = classes == null ? List.of() : List.copyOf(classes);
            subjects = subjects == null ? List.of() : List.copyOf(subjects);
            maxSensitivity = opt(maxSensitivity);
            regex = opt(regex);
            if (maxSensitivity.orElse(null) == SessionJournalRecord.Sensitivity.SECRET) {
                throw new IllegalArgumentException("secret journal records are unavailable in v1");
            }
        }
    }
    public record SessionJournal(
        Stream stream,
        Optional<Cursor> cursor,
        Optional<JournalStart> start,
        Optional<Boolean> follow,
        Optional<JournalFilter> filter
    ) {
        public SessionJournal(
            Stream stream,
            Optional<Cursor> cursor,
            Optional<JournalStart> start,
            Optional<JournalFilter> filter
        ) {
            this(stream, cursor, start, Optional.empty(), filter);
        }

        public SessionJournal {
            stream = Options.stream(stream);
            cursor = opt(cursor);
            start = opt(start);
            follow = opt(follow);
            filter = opt(filter);
            if (cursor.isPresent() && start.isPresent()) {
                throw new IllegalArgumentException("journal cursor and start are mutually exclusive");
            }
        }
    }
    public record CreationResolve(Read read, String correlationKey) {
        public CreationResolve {
            read = Options.read(read);
            Objects.requireNonNull(correlationKey, "correlationKey");
            bounded(correlationKey, "correlationKey", 1, 128);
        }
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
    public record ProjectionPut(
        Mutation mutation,
        String frontendId,
        String windowId,
        String generation,
        Map<String, Object> projection,
        Optional<Decimal> expectedProjectionRevision
    ) {
        public ProjectionPut {
            mutation = mut(mutation);
            Objects.requireNonNull(frontendId, "frontendId");
            Objects.requireNonNull(windowId, "windowId");
            Objects.requireNonNull(generation, "generation");
            projection = copy(projection);
            expectedProjectionRevision = opt(expectedProjectionRevision);
        }
    }
    public record WorkspaceCreate(
        Mutation mutation,
        Optional<String> name,
        InitialContent initialContent,
        Optional<String> correlationKey
    ) {
        public WorkspaceCreate {
            mutation = mut(mutation); name = opt(name);
            initialContent = initialContent == null ? InitialContent.TERMINAL : initialContent;
            correlationKey = correlation(correlationKey);
        }
        public WorkspaceCreate(
            Mutation mutation,
            Optional<String> name,
            InitialContent initialContent
        ) {
            this(mutation, name, initialContent, Optional.empty());
        }
        public static Builder builder() { return new Builder(); }
        public static final class Builder {
            private Mutation mutation = Mutation.defaults();
            private String name;
            private InitialContent initialContent = InitialContent.TERMINAL;
            private String correlationKey;
            public Builder mutation(Mutation value) { mutation = value; return this; }
            public Builder name(String value) { name = value; return this; }
            public Builder initialContent(InitialContent value) { initialContent = value; return this; }
            public Builder correlationKey(String value) {
                correlationKey = value;
                return this;
            }
            public WorkspaceCreate build() {
                return new WorkspaceCreate(
                    mutation,
                    Optional.ofNullable(name),
                    initialContent,
                    Optional.ofNullable(correlationKey)
                );
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
        Optional<Integer> rows,
        Optional<String> correlationKey
    ) {
        public Run {
            mutation = mut(mutation); Objects.requireNonNull(command, "command");
            cwd = opt(cwd); name = opt(name); columns = opt(columns); rows = opt(rows);
            correlationKey = correlation(correlationKey);
        }
        public Run(
            Mutation mutation,
            Command command,
            Optional<String> cwd,
            Optional<String> name,
            Optional<Integer> columns,
            Optional<Integer> rows
        ) {
            this(
                mutation,
                command,
                cwd,
                name,
                columns,
                rows,
                Optional.empty()
            );
        }
        public static Builder builder(Command command) { return new Builder(command); }
        public static final class Builder {
            private Mutation mutation = Mutation.defaults();
            private final Command command;
            private String cwd;
            private String name;
            private Integer columns;
            private Integer rows;
            private String correlationKey;
            private Builder(Command command) { this.command = Objects.requireNonNull(command, "command"); }
            public Builder mutation(Mutation value) { mutation = value; return this; }
            public Builder cwd(String value) { cwd = value; return this; }
            public Builder name(String value) { name = value; return this; }
            public Builder size(int cols, int rowCount) { columns = cols; rows = rowCount; return this; }
            public Builder correlationKey(String value) {
                correlationKey = value;
                return this;
            }
            public Run build() {
                return new Run(
                    mutation,
                    command,
                    Optional.ofNullable(cwd),
                    Optional.ofNullable(name),
                    Optional.ofNullable(columns),
                    Optional.ofNullable(rows),
                    Optional.ofNullable(correlationKey)
                );
            }
        }
    }
    public record LayoutApply(Mutation mutation, Map<String, Object> layout) {
        public LayoutApply { mutation = mut(mutation); layout = copy(layout); }
    }
    public record ScreenCreate(
        Mutation mutation,
        Optional<String> name,
        Optional<String> correlationKey
    ) {
        public ScreenCreate {
            mutation = mut(mutation);
            name = opt(name);
            correlationKey = correlation(correlationKey);
        }
        public ScreenCreate(Mutation mutation, Optional<String> name) {
            this(mutation, name, Optional.empty());
        }
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
    public record LayoutUndo(
        Mutation mutation,
        boolean confirmClose,
        Optional<String> confirmationToken
    ) {
        public LayoutUndo {
            mutation = mut(mutation);
            confirmationToken = opt(confirmationToken);
            confirmationToken.ifPresent(token -> {
                int bytes = token.getBytes(StandardCharsets.UTF_8).length;
                if (bytes < 1 || bytes > 128) {
                    throw new IllegalArgumentException(
                        "confirmationToken must contain 1 to 128 UTF-8 bytes"
                    );
                }
            });
            if (confirmClose && confirmationToken.isEmpty()) {
                throw new IllegalArgumentException(
                    "confirmationToken is required when confirmClose is true"
                );
            }
        }

        public LayoutUndo(Mutation mutation, boolean confirmClose) {
            this(mutation, confirmClose, Optional.empty());
        }

        public static LayoutUndo preview(Mutation mutation) {
            return new LayoutUndo(mutation, false, Optional.empty());
        }

        public static LayoutUndo confirmed(Mutation mutation, String token) {
            return new LayoutUndo(
                mutation,
                true,
                Optional.of(Objects.requireNonNull(token, "token"))
            );
        }
    }
    public record PaneCreate(
        Mutation mutation,
        Optional<String> cwd,
        Optional<Integer> columns,
        Optional<Integer> rows,
        Optional<String> correlationKey
    ) {
        public PaneCreate {
            mutation = mut(mutation); cwd = opt(cwd); columns = opt(columns); rows = opt(rows);
            correlationKey = correlation(correlationKey);
        }
        public PaneCreate(
            Mutation mutation,
            Optional<String> cwd,
            Optional<Integer> columns,
            Optional<Integer> rows
        ) {
            this(mutation, cwd, columns, rows, Optional.empty());
        }
    }
    public record PaneSplit(
        Mutation mutation,
        Direction direction,
        Optional<Double> ratio,
        Optional<String> cwd,
        Optional<Integer> columns,
        Optional<Integer> rows,
        Optional<Double> viewportWidth,
        Optional<String> correlationKey
    ) {
        public PaneSplit {
            mutation = mut(mutation); Objects.requireNonNull(direction, "direction");
            ratio = opt(ratio); cwd = opt(cwd); columns = opt(columns); rows = opt(rows);
            viewportWidth = opt(viewportWidth);
            correlationKey = correlation(correlationKey);
        }
        public PaneSplit(
            Mutation mutation,
            Direction direction,
            Optional<Double> ratio,
            Optional<String> cwd,
            Optional<Integer> columns,
            Optional<Integer> rows,
            Optional<String> correlationKey
        ) {
            this(
                mutation,
                direction,
                ratio,
                cwd,
                columns,
                rows,
                Optional.empty(),
                correlationKey
            );
        }
        public PaneSplit(
            Mutation mutation,
            Direction direction,
            Optional<Double> ratio,
            Optional<String> cwd,
            Optional<Integer> columns,
            Optional<Integer> rows
        ) {
            this(
                mutation,
                direction,
                ratio,
                cwd,
                columns,
                rows,
                Optional.empty(),
                Optional.empty()
            );
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
        Optional<Integer> rows,
        Optional<String> correlationKey
    ) {
        public TabCreateTerminal {
            mutation = mut(mutation); name = opt(name); cwd = opt(cwd); columns = opt(columns); rows = opt(rows);
            correlationKey = correlation(correlationKey);
        }
        public TabCreateTerminal(
            Mutation mutation,
            Optional<String> name,
            Optional<String> cwd,
            Optional<Integer> columns,
            Optional<Integer> rows
        ) {
            this(mutation, name, cwd, columns, rows, Optional.empty());
        }
    }
    public record TabCreateBrowser(
        Mutation mutation,
        Optional<String> name,
        String url,
        Optional<Integer> width,
        Optional<Integer> height,
        Optional<String> correlationKey
    ) {
        public TabCreateBrowser {
            mutation = mut(mutation); name = opt(name); Objects.requireNonNull(url, "url"); width = opt(width); height = opt(height);
            correlationKey = correlation(correlationKey);
        }
        public TabCreateBrowser(
            Mutation mutation,
            Optional<String> name,
            String url,
            Optional<Integer> width,
            Optional<Integer> height
        ) {
            this(mutation, name, url, width, height, Optional.empty());
        }
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
    /** Browser pointer input authorized by one exact attached frame token. */
    public record BrowserMouse(
        Mutation mutation,
        Map<String, Object> mouse,
        Decimal pointerFrameSeq
    ) {
        public BrowserMouse {
            mutation = mut(mutation);
            mouse = copy(mouse);
            Objects.requireNonNull(pointerFrameSeq, "pointerFrameSeq");
        }
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
    public record WaitExit(Read read, Optional<Decimal> timeoutMillis) {
        public WaitExit {
            read = Options.read(read);
            timeoutMillis = opt(timeoutMillis);
        }

        public static WaitExit defaults() {
            return new WaitExit(Read.defaults(), Optional.empty());
        }
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
    public record ViewerSize(
        Control control,
        String attachmentLease,
        int width,
        int height
    ) {
        public ViewerSize {
            control = Options.control(control);
            Objects.requireNonNull(attachmentLease, "attachmentLease");
            bounded(attachmentLease, "attachmentLease", 1, 128);
            nonnegative(width, "width");
            nonnegative(height, "height");
        }
    }
    public record ViewAttachment(Control control, String attachmentLease) {
        public ViewAttachment {
            control = Options.control(control);
            Objects.requireNonNull(attachmentLease, "attachmentLease");
            bounded(attachmentLease, "attachmentLease", 1, 128);
        }
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
    public record TerminalProject(
        Mutation mutation,
        Selector<Ids.WorkspaceId> workspace,
        Selector<Ids.ScreenId> screen,
        Selector<Ids.PaneId> pane,
        int index,
        Optional<String> name
    ) {
        public TerminalProject {
            mutation = mut(mutation); Objects.requireNonNull(workspace, "workspace");
            Objects.requireNonNull(screen, "screen"); Objects.requireNonNull(pane, "pane");
            nonnegative(index, "index"); name = opt(name);
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
    /** Browser wheel input authorized by one exact attached frame token. */
    public record Wheel(
        Mutation mutation,
        double deltaX,
        double deltaY,
        double x,
        double y,
        Decimal pointerFrameSeq
    ) {
        public Wheel {
            mutation = mut(mutation);
            finite(deltaX, "deltaX");
            finite(deltaY, "deltaY");
            finite(x, "x");
            finite(y, "y");
            Objects.requireNonNull(pointerFrameSeq, "pointerFrameSeq");
        }
    }
    public record BrowserAttach(Stream stream, Optional<Integer> width, Optional<Integer> height) {
        public BrowserAttach { stream = Options.stream(stream); width = opt(width); height = opt(height); }
    }
    public record NotificationCreate(
        Mutation mutation,
        String title,
        String body,
        Optional<String> level,
        Optional<Ids.TerminalId> terminalId
    ) {
        public NotificationCreate {
            mutation = mut(mutation);
            Objects.requireNonNull(title, "title");
            Objects.requireNonNull(body, "body");
            level = opt(level);
            terminalId = opt(terminalId);
        }

        public NotificationCreate(
            Mutation mutation,
            String title,
            String body,
            Optional<String> level
        ) {
            this(mutation, title, body, level, Optional.empty());
        }
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
    private Options() {}

    static String validateIdempotencyKey(String key) {
        if (key == null) {
            throw new IllegalArgumentException("idempotency key must be a string");
        }
        int bytes = 0;
        boolean hasNonWhitespace = false;
        for (int index = 0; index < key.length();) {
            char first = key.charAt(index);
            final int codepoint;
            if (Character.isHighSurrogate(first)) {
                if (index + 1 >= key.length() ||
                        !Character.isLowSurrogate(key.charAt(index + 1))) {
                    throw new IllegalArgumentException(
                        "idempotency key must contain valid Unicode scalars"
                    );
                }
                codepoint = Character.toCodePoint(first, key.charAt(index + 1));
                index += 2;
            } else if (Character.isLowSurrogate(first)) {
                throw new IllegalArgumentException(
                    "idempotency key must contain valid Unicode scalars"
                );
            } else {
                codepoint = first;
                index += 1;
            }
            bytes += codepoint <= 0x7F
                ? 1
                : codepoint <= 0x7FF
                    ? 2
                    : codepoint <= 0xFFFF ? 3 : 4;
            if (codepoint <= 0x001F ||
                    (codepoint >= 0x007F && codepoint <= 0x009F)) {
                throw new IllegalArgumentException(
                    "idempotency key must not contain Unicode control characters"
                );
            }
            hasNonWhitespace |= !isUnicodeWhitespace(codepoint);
        }
        if (bytes < 1 || bytes > 128) {
            throw new IllegalArgumentException(
                "idempotency key must contain 1 to 128 UTF-8 bytes"
            );
        }
        if (!hasNonWhitespace) {
            throw new IllegalArgumentException(
                "idempotency key must contain a non-whitespace Unicode scalar"
            );
        }
        return key;
    }

    private static boolean isUnicodeWhitespace(int codepoint) {
        return (codepoint >= 0x0009 && codepoint <= 0x000D) ||
            codepoint == 0x0020 || codepoint == 0x0085 ||
            codepoint == 0x00A0 || codepoint == 0x1680 ||
            (codepoint >= 0x2000 && codepoint <= 0x200A) ||
            codepoint == 0x2028 || codepoint == 0x2029 ||
            codepoint == 0x202F || codepoint == 0x205F ||
            codepoint == 0x3000;
    }

    private static Mutation mut(Mutation value) { return value == null ? Mutation.defaults() : value; }
    private static Read read(Read value) { return value == null ? Read.defaults() : value; }
    private static Control control(Control value) { return value == null ? Control.defaults() : value; }
    private static Stream stream(Stream value) { return value == null ? Stream.defaults() : value; }
    private static <T> Optional<T> opt(Optional<T> value) { return value == null ? Optional.empty() : value; }
    private static Optional<String> correlation(Optional<String> value) {
        Optional<String> result = opt(value);
        result.ifPresent(key -> {
            int bytes = key.getBytes(StandardCharsets.UTF_8).length;
            if (bytes < 1 || bytes > 128) {
                throw new IllegalArgumentException(
                    "correlationKey must contain 1 to 128 UTF-8 bytes"
                );
            }
        });
        return result;
    }
    private static Map<String, Object> copy(Map<String, Object> value) { return value == null ? Map.of() : Map.copyOf(value); }
    private static void nonnegative(long value, String name) { if (value < 0) throw new IllegalArgumentException(name + " must not be negative"); }
    private static void positive(long value, String name) { if (value <= 0) throw new IllegalArgumentException(name + " must be positive"); }
    private static void finite(double value, String name) { if (!Double.isFinite(value)) throw new IllegalArgumentException(name + " must be finite"); }
    private static void bounded(String value, String name, int minimum, int maximum) {
        if (value.length() < minimum || value.length() > maximum) {
            throw new IllegalArgumentException(
                name + " must contain " + minimum + " to " + maximum +
                    " characters"
            );
        }
    }
}
