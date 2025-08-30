import { booksRouter, devServerRouter, healthRouter, usersRouter } from "@/lib/routes/index";
import { integrationsRouter } from "@/lib/routes/integrations.route";
import { stackServerApp } from "@/lib/utils/stack";
import { swaggerUI } from "@hono/swagger-ui";
import { OpenAPIHono } from "@hono/zod-openapi";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { prettyJSON } from "hono/pretty-json";
import { handle } from "hono/vercel";
import { decodeJwt } from "jose";

const app = new OpenAPIHono({
  defaultHook: (result, c) => {
    if (!result.success) {
      const errors = result.error.issues.map((issue) => ({
        path: issue.path,
        message: issue.message,
      }));

      return c.json(
        {
          code: 422,
          message: "Validation Error",
          errors,
        },
        422
      );
    }
  },
}).basePath("/api");

// Debug middleware
app.use("*", async (c, next) => {
  console.log("Request path:", c.req.path);
  console.log("Request url:", c.req.url);
  return next();
});

// Middleware
app.use("*", logger());
app.use("*", prettyJSON());
app.use(
  "*",
  cors({
    origin: ["http://localhost:5173", "http://localhost:9779"],
    credentials: true,
    allowHeaders: ["x-stack-auth"],
  })
);

app.get("/", (c) => {
  return c.text("cmux!");
});

app.get("/user", async (c) => {
  const user = await stackServerApp.getUser({ tokenStore: c.req.raw });
  if (!user) {
    return c.json({ error: "Unauthorized" }, 401);
  }
  const { accessToken } = await user.getAuthJson();
  if (!accessToken) {
    return c.json({ error: "Unauthorized" }, 401);
  }
  const jwt = decodeJwt(accessToken);

  return c.json({
    user,
    jwt,
  });
});

// Routes - Next.js passes the full /api/* path
app.route("/", healthRouter);
app.route("/", usersRouter);
app.route("/", booksRouter);
app.route("/", devServerRouter);
app.route("/", integrationsRouter);

// OpenAPI documentation
app.doc("/doc", {
  openapi: "3.0.0",
  info: {
    version: "1.0.0",
    title: "cmux API",
    description: "API for cmux",
  },
});

app.get("/swagger", swaggerUI({ url: "/doc" }));

// 404 handler
app.notFound((c) => {
  return c.json(
    {
      code: 404,
      message: `Route ${c.req.path} not found`,
    },
    404
  );
});

// Error handler
app.onError((err, c) => {
  console.error(`${err}`);
  return c.json(
    {
      code: 500,
      message: "Internal Server Error",
    },
    500
  );
});

export const GET = handle(app);
export const POST = handle(app);
export const PUT = handle(app);
export const DELETE = handle(app);
export const PATCH = handle(app);
export const OPTIONS = handle(app);
