import { api } from "@cmux/convex/api";
import { StackAdminApp } from "@stackframe/js";
import { ConvexHttpClient } from "convex/browser";

const stackAdminApp = new StackAdminApp({
  tokenStore: "memory",
  projectId: process.env.VITE_STACK_PROJECT_ID,
  publishableClientKey: process.env.VITE_STACK_PUBLISHABLE_CLIENT_KEY,
  secretServerKey: process.env.STACK_SECRET_SERVER_KEY,
  superSecretAdminKey: process.env.STACK_SUPER_SECRET_ADMIN_KEY,
});

const user = await stackAdminApp.getUser(
  "477b6de8-075a-45ea-9c59-f65a65cb124d"
);

if (!user) {
  throw new Error("User not found");
}

const session = await user.createSession({ expiresInMillis: 10_000_000 });
const tokens = await session.getTokens();

const token = tokens.accessToken;
if (!token) {
  throw new Error("Token not found");
}
console.log("token", token);

const url = "https://polite-canary-804.convex.cloud";

const client = new ConvexHttpClient(url);
client.setAuth(token);

const result = await client.query(api.teams.listTeamMemberships);

console.log(result);
