package com.cmux.raw;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import java.util.Objects;
import java.util.regex.Pattern;

/** Normative Unix socket discovery shared by the client and tests. */
public final class SocketDiscovery {
    private static final Pattern SESSION = Pattern.compile("[A-Za-z0-9][A-Za-z0-9._-]{0,63}");

    private SocketDiscovery() {}

    public static Path resolve(Path explicitSocket, String session) {
        return resolve(explicitSocket, session, System.getenv(), currentUid());
    }

    static Path resolve(
        Path explicitSocket,
        String session,
        Map<String, String> environment,
        String uid
    ) {
        if (explicitSocket != null) {
            return explicitSocket;
        }
        String inherited = nonBlank(environment.get("CMUX_TUI_SOCKET"));
        if (inherited == null) {
            inherited = nonBlank(environment.get("CMUX_MUX_SOCKET"));
        }
        if (inherited != null) {
            return Path.of(inherited);
        }
        validateSession(session);
        String root = nonBlank(environment.get("XDG_RUNTIME_DIR"));
        if (root == null) {
            root = nonBlank(environment.get("TMPDIR"));
        }
        if (root == null) {
            root = "/tmp";
        }
        String fileName = session + ".sock";
        Path preferred = Path.of(root, "cmux-tui-" + uid, fileName);
        if (fitsUnixSocket(preferred)) {
            return preferred;
        }
        return Path.of("/tmp", "cmux-tui-" + uid, fileName);
    }

    public static Path defaultSocketPath(String session) {
        return resolve(null, session);
    }

    public static void validateSession(String session) {
        Objects.requireNonNull(session, "session");
        if (!SESSION.matcher(session).matches()
                || session.equals(".")
                || session.equals("..")) {
            throw new IllegalArgumentException(
                "session must match [A-Za-z0-9][A-Za-z0-9._-]{0,63} and not be . or .."
            );
        }
    }

    static boolean fitsUnixSocket(Path path) {
        int capacity = System.getProperty("os.name", "")
            .toLowerCase()
            .contains("mac") ? 104 : 108;
        return path.toString().getBytes(StandardCharsets.UTF_8).length < capacity;
    }

    static String currentUid() {
        Path probe = null;
        try {
            probe = Files.createTempFile("cmux-tui-java-uid", ".tmp");
            Object uid = Files.getAttribute(probe, "unix:uid");
            return String.valueOf(uid);
        } catch (IOException | UnsupportedOperationException error) {
            String uid = nonBlank(System.getenv("UID"));
            return uid != null ? uid : System.getProperty("user.name", "0");
        } finally {
            if (probe != null) {
                try {
                    Files.deleteIfExists(probe);
                } catch (IOException ignored) {
                    // best effort
                }
            }
        }
    }

    private static String nonBlank(String value) {
        return value == null || value.isBlank() ? null : value;
    }
}
