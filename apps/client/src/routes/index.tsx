import { createFileRoute, Navigate } from '@tanstack/react-router'
// import { useUser } from '@stackframe/react'

export const Route = createFileRoute('/')({
  component: IndexRoute,
})

function IndexRoute() {
  // const user = useUser({ or: 'return-null' })
  
  // If user is logged in, redirect to dashboard
  // if (user) {
  //   return <Navigate to="/dashboard" />
  // }
  
  // Otherwise, show the landing page
  return <Navigate to="/landing" />
}