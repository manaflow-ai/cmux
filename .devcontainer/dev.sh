#!/bin/bash

set -e

# Build the worker image
if command -v docker &> /dev/null; then
    docker build -t cmux-worker:0.0.1 /workspace
else
    echo -e "${RED}Docker not available in container${NC}"
    exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP_DIR="/workspace"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}Starting Terminal App Development Environment in Devcontainer...${NC}"

# Change to app directory
cd "$APP_DIR"

# Function to cleanup on exit
cleanup() {
    echo -e "\n${BLUE}Shutting down...${NC}"
    kill $SERVER_PID $CLIENT_PID $CONVEX_DEV_PID 2>/dev/null
    exit
}

# Set up trap to cleanup on script exit
trap cleanup EXIT INT TERM

# Check if node_modules exist, if not install dependencies
if [ ! -d "node_modules" ] || [ "$FORCE_INSTALL" = "true" ]; then
    echo -e "${BLUE}Installing dependencies...${NC}"
    CI=1 pnpm install --frozen-lockfile
fi

# Function to prefix output with colored labels
prefix_output() {
    local label="$1"
    local color="$2"
    while IFS= read -r line; do
        echo -e "${color}[${label}]${NC} $line"
    done
}

# Create logs directory if it doesn't exist
mkdir -p "$APP_DIR/logs"

# Start convex dev (without backend since it's running in docker-compose)
echo -e "${GREEN}Starting convex dev...${NC}"
(cd packages/convex-local && \
  if [ -f "$HOME/.nvm/nvm.sh" ]; then \
    source $HOME/.nvm/nvm.sh && nvm use 18; \
  fi && \
  bunx convex dev --url http://backend:3210 --admin-key "$CONVEX_SELF_HOSTED_ADMIN_KEY" \
    2>&1 | tee ../../logs/convex-dev.log | prefix_output "CONVEX-DEV" "$GREEN") &
CONVEX_DEV_PID=$!

# Wait a bit for convex to initialize
sleep 5

# Start the backend server
echo -e "${GREEN}Starting backend server on port 9776...${NC}"
(cd apps/server-local && VITE_CONVEX_URL=http://backend:3210 bun run dev 2>&1 | prefix_output "SERVER" "$YELLOW") &
SERVER_PID=$!

# Start the frontend
echo -e "${GREEN}Starting frontend on port 5173...${NC}"
(cd apps/client && VITE_CONVEX_URL=http://localhost:9777 bun run dev 2>&1 | prefix_output "CLIENT" "$CYAN") &
CLIENT_PID=$!

echo -e "${GREEN}Terminal app is running!${NC}"
echo -e "${BLUE}Frontend: http://localhost:5173${NC}"
echo -e "${BLUE}Backend: http://localhost:9776${NC}"
echo -e "${BLUE}Convex Backend: http://localhost:3210${NC}"
echo -e "${BLUE}Convex Dashboard: http://localhost:6791${NC}"
echo -e "\nPress Ctrl+C to stop all services"

# Wait for both processes
wait