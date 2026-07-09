package com.cmux;

import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Arrays;

public final class WireCaptureTest {
    public static void main(String[] args) throws Exception {
        byte[] identify = captureIdentify();
        byte[] attach = captureAttach(9);
        printCapture("JAVA identify", identify);
        printCapture("JAVA attach", attach);
        assertLine("identify", "{\"id\":1,\"cmd\":\"identify\"}\n", identify);
        assertLine("attach", "{\"cmd\":\"attach-surface\",\"surface\":9,\"id\":2}\n", attach);
    }

    private static byte[] captureIdentify() throws Exception {
        Path socket = freshSocketPath();
        CaptureServer server = new CaptureServer(socket, new String[] {
            "{\"id\":1,\"ok\":true,\"data\":{\"app\":\"cmux-tui\",\"version\":\"test\",\"protocol\":6,\"session\":\"wire\",\"pid\":1}}"
        });
        server.start();
        try (CmuxClient client = CmuxClient.builder().socketPath(socket.toString()).timeout(Duration.ofSeconds(2)).build()) {
            client.identify();
        } finally {
            server.close();
        }
        return server.firstLine(0);
    }

    private static byte[] captureAttach(long surface) throws Exception {
        Path socket = freshSocketPath();
        CaptureServer server = new CaptureServer(socket, new String[] {
            "{\"id\":1,\"ok\":true,\"data\":{\"app\":\"cmux-tui\",\"version\":\"test\",\"protocol\":6,\"session\":\"wire\",\"pid\":1}}",
            "{\"event\":\"vt-state\",\"surface\":" + surface + ",\"cols\":80,\"rows\":24,\"data\":\"\"}"
        });
        server.start();
        try (CmuxClient client = CmuxClient.builder().socketPath(socket.toString()).timeout(Duration.ofSeconds(2)).build()) {
            try (CmuxClient.CmuxStream ignored = client.attachSurface(surface)) {
                // Opening the stream is enough to capture the attach request.
            }
        } finally {
            server.close();
        }
        return server.firstLine(1);
    }

    private static Path freshSocketPath() throws IOException {
        Path socket = Files.createTempFile("cmux-java-wire", ".sock");
        Files.deleteIfExists(socket);
        return socket;
    }

    private static void printCapture(String label, byte[] bytes) {
        System.out.println(label + " utf8=" + new String(bytes, StandardCharsets.UTF_8).replace("\n", "\\n"));
        System.out.println(label + " hex=" + hex(bytes));
    }

    private static String hex(byte[] bytes) {
        StringBuilder out = new StringBuilder();
        for (byte b : bytes) {
            if (!out.isEmpty()) {
                out.append(' ');
            }
            out.append(String.format("%02x", b & 0xff));
        }
        return out.toString();
    }

    private static void assertLine(String label, String expected, byte[] actual) {
        String text = new String(actual, StandardCharsets.UTF_8);
        if (!expected.equals(text)) {
            throw new AssertionError(label + " wire mismatch expected=" + expected + " actual=" + text);
        }
    }

    private static final class CaptureServer implements AutoCloseable {
        private final Path socket;
        private final String[] responses;
        private final byte[][] lines;
        private Thread thread;
        private ServerSocketChannel server;

        CaptureServer(Path socket, String[] responses) {
            this.socket = socket;
            this.responses = responses;
            this.lines = new byte[responses.length][];
        }

        void start() throws Exception {
            server = ServerSocketChannel.open(StandardProtocolFamily.UNIX);
            server.bind(UnixDomainSocketAddress.of(socket));
            thread = new Thread(this::run, "wire-capture-server");
            thread.setDaemon(true);
            thread.start();
        }

        byte[] firstLine(int index) throws Exception {
            if (thread != null) {
                thread.join(5_000);
            }
            if (lines[index] == null) {
                throw new AssertionError("missing captured line " + index + " captured=" + Arrays.deepToString(lines));
            }
            return lines[index];
        }

        private void run() {
            try {
                for (int i = 0; i < responses.length; i++) {
                    try (SocketChannel client = server.accept()) {
                        lines[i] = readLine(client);
                        writeLine(client, responses[i]);
                    }
                }
            } catch (Exception err) {
                throw new RuntimeException(err);
            }
        }

        @Override
        public void close() throws Exception {
            if (server != null) {
                server.close();
            }
            Files.deleteIfExists(socket);
        }
    }

    private static byte[] readLine(SocketChannel client) throws IOException {
        ByteBuffer one = ByteBuffer.allocate(1);
        byte[] bytes = new byte[0];
        while (client.read(one) >= 0) {
            one.flip();
            if (one.hasRemaining()) {
                byte b = one.get();
                bytes = Arrays.copyOf(bytes, bytes.length + 1);
                bytes[bytes.length - 1] = b;
                if (b == '\n') {
                    return bytes;
                }
            }
            one.clear();
        }
        throw new IOException("client closed before newline");
    }

    private static void writeLine(SocketChannel client, String line) throws IOException {
        ByteBuffer bytes = ByteBuffer.wrap((line + "\n").getBytes(StandardCharsets.UTF_8));
        while (bytes.hasRemaining()) {
            client.write(bytes);
        }
    }
}
