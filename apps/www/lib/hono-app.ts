import { githubPrsBackfillRepoRouter } from "@/lib/routes/github.prs.backfill-repo.route";
import { githubPrsBackfillRouter } from "@/lib/routes/github.prs.backfill.route";
import { githubPrsCodeRouter } from "@/lib/routes/github.prs.code.route";
import { githubPrsFileContentsBatchRouter } from "@/lib/routes/github.prs.file-contents-batch.route";
import { githubPrsFileContentsRouter } from "@/lib/routes/github.prs.file-contents.route";
import { githubPrsFilesRouter } from "@/lib/routes/github.prs.files.route";
import { githubPrsOpenRouter } from "@/lib/routes/github.prs.open.route";
import { githubPrsPatchRouter } from "@/lib/routes/github.prs.patch.route";
import { githubPrsRouter } from "@/lib/routes/github.prs.route";
import { githubReposRouter } from "@/lib/routes/github.repos.route";
import {
  booksRouter,
  branchRouter,
  codeReviewRouter,
  devServerRouter,
  environmentsRouter,
  githubInstallStateRouter,
  healthRouter,
  morphRouter,
  sandboxesRouter,
  teamsRouter,
  usersRouter,
  iframePreflightRouter,
  workspaceConfigsRouter,
  previewRouter,
} from "@/lib/routes/index";
import { authAnonymousRouter } from "@/lib/routes/auth.anonymous.route";
import { stackServerApp } from "@/lib/utils/stack";
import { swaggerUI } from "@hono/swagger-ui";
import { OpenAPIHono } from "@hono/zod-openapi";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { prettyJSON } from "hono/pretty-json";
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
        422,
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
    origin: [
      "http://localhost:5173",
      "http://localhost:9779",
      "https://cmux.sh",
      "https://www.cmux.sh",
    ],
    credentials: true,
    allowHeaders: ["x-stack-auth", "content-type", "authorization"],
  }),
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
app.route("/", authAnonymousRouter);
app.route("/", usersRouter);
app.route("/", booksRouter);
app.route("/", devServerRouter);
app.route("/", githubReposRouter);
app.route("/", githubPrsRouter);
app.route("/", githubPrsBackfillRouter);
app.route("/", githubPrsBackfillRepoRouter);
app.route("/", githubPrsCodeRouter);
app.route("/", githubPrsOpenRouter);
app.route("/", githubPrsPatchRouter);
app.route("/", githubPrsFilesRouter);
app.route("/", githubPrsFileContentsRouter);
app.route("/", githubPrsFileContentsBatchRouter);
app.route("/", githubInstallStateRouter);
app.route("/", morphRouter);
app.route("/", iframePreflightRouter);
app.route("/", environmentsRouter);
app.route("/", sandboxesRouter);
app.route("/", teamsRouter);
app.route("/", branchRouter);
app.route("/", codeReviewRouter);
app.route("/", workspaceConfigsRouter);
app.route("/", previewRouter);

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
    404,
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
    500,
  );
});

export { app };
