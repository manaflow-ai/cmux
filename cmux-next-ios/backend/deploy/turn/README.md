# Our own TURN relay

Why: Cloudflare Realtime TURN is metered at $0.05 per GB egress. Direct paths cost nothing; the relay is only
the fallback for networks that block UDP (enterprise firewalls that pass TCP 443 only). We own that fallback.

Deploy (one box per region, two to start; the client already tries every URL it is given):

1. A Hetzner-class host with a public IPv4. Point `relay.cmux.dev` (DNS only, not proxied) at it. Get a
   certificate for it (certbot) into `/etc/eturnal/tls/`.
2. Run eturnal with `eturnal.yml` (`ETURNAL_SECRET` and `RELAY_PUBLIC_IPV4` from the environment). Open
   udp+tcp 3478, tcp 443, udp 49152-65535.
3. Set the Worker's secrets (per env): `TURN_SELF_URLS` =
   `turn:relay.cmux.dev:3478?transport=udp,turn:relay.cmux.dev:3478?transport=tcp,turns:relay.cmux.dev:443?transport=tcp`
   and `TURN_SELF_SECRET` = the same secret. `/v1/ice` then mints HMAC credentials locally and stops calling
   Cloudflare. Unset both to go back.
4. Check: `/v1/ice` lists the URLs, and a dial from a UDP-blocked network reports path `turn-tls`
   (`review.sh --require-turn`, cmux#52947).
