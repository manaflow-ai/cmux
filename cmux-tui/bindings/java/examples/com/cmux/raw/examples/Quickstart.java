package com.cmux.examples;

import com.cmux.CmuxClient;
import com.cmux.UInt64;
import com.cmux.generated.IdentifyResult;
import com.cmux.generated.ReadScreenRequest;
import com.cmux.generated.SendRequest;

public final class Quickstart {
    private Quickstart() {}

    public static void main(String[] args) throws Exception {
        try (CmuxClient client = CmuxClient.builder().build()) {
            IdentifyResult server = client.identify();
            System.out.println("cmux protocol " + server.protocol());

            UInt64 surface = UInt64.parse(args[0]);
            client.send(
                SendRequest.builder()
                    .surface(surface)
                    .text("printf 'hello from Java\\r'")
                    .build()
            );
            System.out.println(
                client.readScreen(ReadScreenRequest.builder().surface(surface).build()).text()
            );
        }
    }
}
