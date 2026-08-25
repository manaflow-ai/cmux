package com.cmux;

import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** Concrete non-resource results named by the protocol-v2 operation catalog. */
public final class Results {
    public record PingResult(boolean alive, Cursor cursor) {
        public PingResult {
            Objects.requireNonNull(cursor, "cursor");
        }
    }

    public record ShutdownResult(boolean accepted) {}

    public record ReloadConfigResult(boolean reloaded, List<String> warnings) {
        public ReloadConfigResult {
            warnings = List.copyOf(warnings);
        }
    }

    /** Three-state optional nullable terminal default. */
    public record NullableDefault<T>(boolean present, Optional<T> value) {
        public NullableDefault {
            value = value == null ? Optional.empty() : value;
            if (!present && value.isPresent()) {
                throw new IllegalArgumentException(
                    "an absent nullable field cannot carry a value"
                );
            }
        }

        public static <T> NullableDefault<T> absent() {
            return new NullableDefault<>(false, Optional.empty());
        }

        public static <T> NullableDefault<T> nullValue() {
            return new NullableDefault<>(true, Optional.empty());
        }

        public static <T> NullableDefault<T> of(T value) {
            return new NullableDefault<>(
                true,
                Optional.of(Objects.requireNonNull(value, "value"))
            );
        }
    }

    public record TerminalDefaultsSnapshot(
        NullableDefault<String> foreground,
        NullableDefault<String> background,
        NullableDefault<String> cursor,
        NullableDefault<String> selectionBackground,
        NullableDefault<String> selectionForeground,
        NullableDefault<String> cursorStyle,
        NullableDefault<Boolean> cursorBlink,
        Optional<Map<String, String>> palette
    ) {
        public TerminalDefaultsSnapshot {
            foreground = defaultValue(foreground);
            background = defaultValue(background);
            cursor = defaultValue(cursor);
            selectionBackground = defaultValue(selectionBackground);
            selectionForeground = defaultValue(selectionForeground);
            cursorStyle = defaultValue(cursorStyle);
            cursorBlink = defaultValue(cursorBlink);
            palette = palette == null ? Optional.empty() :
                palette.map(Map::copyOf);
            cursorStyle.value().ifPresent(value -> {
                if (!List.of("block", "bar", "underline").contains(value)) {
                    throw new IllegalArgumentException(
                        "cursorStyle has an unsupported value"
                    );
                }
            });
        }
    }

    public record PairingResolutionResult(
        Snapshots.PairingRequestSnapshot pairingRequest
    ) {
        public PairingResolutionResult {
            Objects.requireNonNull(pairingRequest, "pairingRequest");
        }
    }

    public record PaneNeighborResult(Optional<Snapshots.PaneSnapshot> pane) {
        public PaneNeighborResult {
            pane = pane == null ? Optional.empty() : pane;
        }
    }

    public record TerminalScreenResult(
        String text,
        int cols,
        int rows,
        int cursorRow,
        int cursorCol,
        boolean cursorVisible,
        Map<String, Object> extra
    ) {
        public TerminalScreenResult {
            Objects.requireNonNull(text, "text");
            positiveUint16(cols, "cols");
            positiveUint16(rows, "rows");
            uint16(cursorRow, "cursorRow");
            uint16(cursorCol, "cursorCol");
            extra = extra == null
                ? Map.of()
                : JsonValue.immutableObject(extra, "terminal screen extra");
        }
    }

    public record TerminalHistoryResult(
        Decimal start,
        NullableDefault<Decimal> next,
        List<Render.Row> rows
    ) {
        public TerminalHistoryResult {
            Objects.requireNonNull(start, "start");
            next = defaultValue(next);
            rows = List.copyOf(rows);
        }
    }

    public record TerminalStateResult(byte[] state, int cols, int rows) {
        public TerminalStateResult {
            state = Arrays.copyOf(state, state.length);
            positiveUint16(cols, "cols");
            positiveUint16(rows, "rows");
        }

        @Override
        public byte[] state() {
            return Arrays.copyOf(state, state.length);
        }
    }

    public record TerminalWaitResult(boolean matched, String text) {
        public TerminalWaitResult {
            Objects.requireNonNull(text, "text");
        }
    }

    public enum CreationState {
        PENDING,
        CREATED,
        NOT_APPLIED,
        INDETERMINATE
    }

    public enum CreationRecovery {
        RETRY_SAME_IDEMPOTENCY_KEY,
        RETRY_NEW_IDEMPOTENCY_KEY,
        WAIT,
        NONE,
        DO_NOT_RETRY
    }

    public record CreationResolution(
        String correlationKey,
        CreationState state,
        CreationRecovery recovery,
        Optional<String> operation,
        Optional<String> idempotencyKey,
        Optional<CreatedPath> createdPath,
        Optional<String> generation,
        Optional<Decimal> revision
    ) {
        public CreationResolution {
            bounded(correlationKey, "correlationKey", 1, 128);
            Objects.requireNonNull(state, "state");
            Objects.requireNonNull(recovery, "recovery");
            operation = optional(operation);
            idempotencyKey = optional(idempotencyKey);
            createdPath = optional(createdPath);
            generation = optional(generation);
            revision = optional(revision);
            operation.ifPresent(value -> bounded(value, "operation", 1, Integer.MAX_VALUE));
            idempotencyKey.ifPresent(Options::validateIdempotencyKey);
            generation.ifPresent(
                value -> bounded(value, "generation", 1, 128)
            );
            switch (state) {
                case CREATED -> {
                    if (recovery != CreationRecovery.NONE ||
                            createdPath.isEmpty() ||
                            generation.isEmpty() ||
                            revision.isEmpty()) {
                        throw new IllegalArgumentException(
                            "created resolution requires none recovery, path, generation, and revision"
                        );
                    }
                }
                case PENDING -> {
                    if (recovery != CreationRecovery.WAIT) {
                        throw new IllegalArgumentException(
                            "pending resolution requires wait recovery"
                        );
                    }
                }
                case NOT_APPLIED -> {
                    if (recovery !=
                            CreationRecovery.RETRY_SAME_IDEMPOTENCY_KEY &&
                            recovery !=
                            CreationRecovery.RETRY_NEW_IDEMPOTENCY_KEY) {
                        throw new IllegalArgumentException(
                            "not-applied resolution requires a retry recovery"
                        );
                    }
                }
                case INDETERMINATE -> {
                    if (recovery != CreationRecovery.DO_NOT_RETRY) {
                        throw new IllegalArgumentException(
                            "indeterminate resolution requires do-not-retry recovery"
                        );
                    }
                }
            }
        }
    }

    public sealed interface TerminalExitOutcome permits
            TerminalExitCode, TerminalExitSignal, TerminalExitUnknown {}

    public record TerminalExitCode(int code)
            implements TerminalExitOutcome {}

    public record TerminalExitSignal(int signal, boolean coreDumped)
            implements TerminalExitOutcome {
        public TerminalExitSignal {
            if (signal <= 0) {
                throw new IllegalArgumentException("signal must be positive");
            }
        }
    }

    public record TerminalExitUnknown(String reason)
            implements TerminalExitOutcome {
        public TerminalExitUnknown {
            bounded(reason, "reason", 1, Integer.MAX_VALUE);
        }
    }

    public sealed interface TerminalWaitExitResult permits
            TerminalWaitExitPending, TerminalWaitExitExited {
        Ids.TerminalId terminalId();
        Decimal revision();
    }

    public record TerminalWaitExitPending(
        Ids.TerminalId terminalId,
        String lifecycle,
        Decimal revision
    ) implements TerminalWaitExitResult {
        public TerminalWaitExitPending {
            Objects.requireNonNull(terminalId, "terminalId");
            if (!List.of("launching", "running").contains(lifecycle)) {
                throw new IllegalArgumentException(
                    "pending terminal lifecycle is unsupported"
                );
            }
            Objects.requireNonNull(revision, "revision");
        }
    }

    public record TerminalWaitExitExited(
        Ids.TerminalId terminalId,
        TerminalExitOutcome outcome,
        Decimal exitedAt,
        Decimal revision
    ) implements TerminalWaitExitResult {
        public TerminalWaitExitExited {
            Objects.requireNonNull(terminalId, "terminalId");
            Objects.requireNonNull(outcome, "outcome");
            Objects.requireNonNull(exitedAt, "exitedAt");
            Objects.requireNonNull(revision, "revision");
        }
    }

    public record TerminalCopyResult(String mode, String text) {
        public TerminalCopyResult {
            if (!List.of("screen", "selection", "scrollback").contains(mode)) {
                throw new IllegalArgumentException("mode has an unsupported value");
            }
            Objects.requireNonNull(text, "text");
        }
    }

    public record ProcessInfoResult(
        long pid,
        Optional<String> executable,
        List<String> argv,
        Optional<String> cwd,
        List<Long> children
    ) {
        public ProcessInfoResult {
            uint32(pid, "pid");
            executable = executable == null ? Optional.empty() : executable;
            argv = List.copyOf(argv);
            cwd = cwd == null ? Optional.empty() : cwd;
            children = List.copyOf(children);
            children.forEach(value -> uint32(value, "child pid"));
        }
    }

    public record CellPixelsResult(
        long widthPx,
        long heightPx,
        List<Ids.TerminalId> resizedTerminals,
        Map<String, String> failures
    ) {
        public CellPixelsResult {
            positiveUint32(widthPx, "widthPx");
            positiveUint32(heightPx, "heightPx");
            resizedTerminals = List.copyOf(resizedTerminals);
            failures = Map.copyOf(failures);
        }
    }

    public enum ViewAttachmentOutcome {
        APPLIED,
        PASSIVE,
        SUPERSEDED
    }

    public record ViewerResizeResult(
        boolean accepted,
        Snapshots.Size size,
        ViewAttachmentOutcome outcome
    ) {
        public ViewerResizeResult {
            Objects.requireNonNull(size, "size");
            Objects.requireNonNull(outcome, "outcome");
        }
    }

    public record BrowserViewerResizeResult(
        boolean accepted,
        Snapshots.PixelSize size,
        ViewAttachmentOutcome outcome
    ) {
        public BrowserViewerResizeResult {
            Objects.requireNonNull(size, "size");
            Objects.requireNonNull(outcome, "outcome");
        }
    }

    public record ViewerReleaseResult(ViewAttachmentOutcome outcome) {
        public ViewerReleaseResult {
            Objects.requireNonNull(outcome, "outcome");
        }
    }

    private Results() {}

    private static <T> NullableDefault<T> defaultValue(
        NullableDefault<T> value
    ) {
        return value == null ? NullableDefault.absent() : value;
    }

    private static <T> Optional<T> optional(Optional<T> value) {
        return value == null ? Optional.empty() : value;
    }

    private static void bounded(
        String value,
        String name,
        int minimum,
        int maximum
    ) {
        Objects.requireNonNull(value, name);
        if (value.length() < minimum || value.length() > maximum) {
            throw new IllegalArgumentException(
                name + " length is outside its protocol bounds"
            );
        }
    }

    private static void positiveUint16(long value, String name) {
        uint16(value, name);
        if (value == 0) {
            throw new IllegalArgumentException(name + " must be positive");
        }
    }

    private static void uint16(long value, String name) {
        if (value < 0 || value > 0xffffL) {
            throw new IllegalArgumentException(name + " must fit uint16");
        }
    }

    private static void positiveUint32(long value, String name) {
        uint32(value, name);
        if (value == 0) {
            throw new IllegalArgumentException(name + " must be positive");
        }
    }

    private static void uint32(long value, String name) {
        if (value < 0 || value > 0xffff_ffffL) {
            throw new IllegalArgumentException(name + " must fit uint32");
        }
    }
}
