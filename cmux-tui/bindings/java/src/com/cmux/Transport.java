package com.cmux;

import java.io.IOException;
import java.util.Map;

/** Injectable message transport for Unix sockets, WebSockets, and tests. */
public interface Transport extends AutoCloseable {
    void send(Map<String, Object> message) throws IOException;

    Map<String, Object> receive() throws IOException;

    @Override
    void close() throws IOException;
}
