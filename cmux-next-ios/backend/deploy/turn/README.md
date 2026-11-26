# Our own TURN relay

Why: Cloudflare Realtime TURN is metered at $0.05 per GB egress. Direct paths cost nothing; the relay is only
the fallback for networks that block UDP (enterprise firewalls that pass TCP 443 only). We own that fallback.

Deploy (one box per region, two to start; the client already tries every URL it is given):

1. A Hetzner-class host with a public IPv4. Point `relay.cmux.dev` (DNS only, not proxied) at it. Get a
   certificate for it (certbot) into `/etc/eturnal/tls/`.
2. Run eturnal with `eturnal.yml` (`ETURNAL_SECRET` and `RELAY_PUBLIC_IPV4` from the environment). Open
   udp+tcp 3478, udp+tcp 443, udp 49152-65535. The client keeps its direct route first and only
   falls back to these own-relay candidates when direct ICE fails.
3. Set the Worker's secrets (per env): `TURN_SELF_URLS` =
   `turn:relay.cmux.dev:3478?transport=udp,turn:relay.cmux.dev:3478?transport=tcp,turn:relay.cmux.dev:443?transport=udp,turns:relay.cmux.dev:443?transport=tcp`
   and `TURN_SELF_SECRET` = the same secret. `/v1/ice` then mints HMAC credentials locally and stops calling
   Cloudflare. Unset both to go back.
4. Check: `/v1/ice` lists the URLs, and a dial from a UDP-blocked network reports path `turn-tls`
   (`review.sh --require-turn`, cmux#52947).

## One-script deploy and the UDP-blocked proof

- `install.sh` (root, any systemd Linux box): downloads eturnal, renders `eturnal.yml` from `ETURNAL_SECRET`,
  the box's public IPv4 and the TLS certificate, and starts the `eturnal` systemd unit.
  `ETURNAL_SECRET=... RELAY_DOMAIN=relay.cmux.dev ./install.sh`. `cloud-init.yaml` is the same as user-data.
  Buying the host, the DNS name and the certificate is Leo's list (RFD 0088 "What to buy").
- `test-udp-blocked.sh` (any Linux, no root): starts a real eturnal with only a TLS listener and runs the
  client with UDP blocked; it fails unless both sides report path `turn-tls`.
  `cmux-ci test -- cmux-next-ios/backend/deploy/turn/test-udp-blocked.sh`.
